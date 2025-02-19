/*
* Copyright (c) 2023, NVIDIA CORPORATION.  All rights reserved.
*
* NVIDIA CORPORATION and its licensors retain all intellectual property
* and proprietary rights in and to this software, related documentation
* and any modifications thereto.  Any use, reproduction, disclosure or
* distribution of this software and related documentation without an express
* license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#ifndef __BxDF_HLSLI__ // using instead of "#pragma once" due to https://github.com/microsoft/DirectXShaderCompiler/issues/3943
#define __BxDF_HLSLI__

#include "../../Config.h"    

#include "../../Utils/Math/MathConstants.hlsli"

#include "BxDFConfig.hlsli"

#include "../../Scene/ShadingData.hlsli"
#include "../../Utils/Math/MathHelpers.hlsli"
#include "../../Utils/Color/ColorHelpers.hlsli"
#include "Fresnel.hlsli"
#include "Microfacet.hlsli"

#include "../../StablePlanes.hlsli"

// Minimum cos(theta) for the incident and outgoing vectors.
// Some BSDF functions are not robust for cos(theta) == 0.0,
// so using a small epsilon for consistency.
static const float kMinCosTheta = 1e-6f;

// Because sample values must be strictly less than 1, it�s useful to define a constant, OneMinusEpsilon, that represents the largest 
// representable floating-point constant that is less than 1. (https://www.pbr-book.org/3ed-2018/Sampling_and_Reconstruction/Sampling_Interface)
static const float OneMinusEpsilon = 0x1.fffffep-1;

// import Scene.ShadingData;
// import Utils.Math.MathHelpers;
// import Utils.Color.ColorHelpers;
// import Rendering.Materials.Fresnel;
// import Rendering.Materials.Microfacet;
// __exported import Rendering.Materials.IBxDF;

// Enable support for delta reflection/transmission.
#define EnableDeltaBSDF         1

// Enable GGX sampling using the distribution of visible normals (VNDF) instead of classic NDF sampling.
// This should be the default as it has lower variance, disable for testing only.
// TODO: Make default when transmission with VNDF sampling is properly validated
#define EnableVNDFSampling      1

// Enable explicitly computing sampling weights using eval(wi, wo) / evalPdf(wi, wo).
// This is for testing only, as many terms of the equation cancel out allowing to save on computation.
#define ExplicitSampleWeights   0

// When deciding a lobe to sample, expand and reuse the random sample - losing at precision but gaining on performance when using costly LD sampler
#define RecycleSelectSamples    1

// We clamp the GGX width parameter to avoid numerical instability.
// In some computations, we can avoid clamps etc. if 1.0 - alpha^2 != 1.0, so the epsilon should be 1.72666361e-4 or larger in fp32.
// The the value below is sufficient to avoid visible artifacts.
// Falcor used to clamp roughness to 0.08 before the clamp was removed for allowing delta events. We continue to use the same threshold.
static const float kMinGGXAlpha = 0.0064f;

// Note: preGeneratedSample argument value in 'sample' interface is a vector of 3 or 4 [0, 1) random numbers, generated with the SampleGenerator and 
// depending on configuration will either be a pseudo-random or quasi-random.
// Some quasi-random (Low Discrepancy / Stratified) samples are such that dimensions are designed to work well in pairs, so ideally use .xy for lobe
// projection sample and .z for lobe selection (if used).
// For more info see https://www.pbr-book.org/3ed-2018/Sampling_and_Reconstruction/Stratified_Sampling

/** Lambertian diffuse reflection.
    f_r(wi, wo) = albedo / pi
*/
struct DiffuseReflectionLambert // : IBxDF
{
    float3 albedo;  ///< Diffuse albedo.

    float3 eval(const float3 wi, const float3 wo)
    {
        if (min(wi.z, wo.z) < kMinCosTheta) return float3(0,0,0);

        return M_1_PI * albedo * wo.z;
    }

    bool sample(const float3 wi, out float3 wo, out float pdf, out float3 weight, out uint lobe, out float lobeP, float3 preGeneratedSample)
    {
        wo = sample_cosine_hemisphere_concentric(preGeneratedSample.xy, pdf);
        lobe = (uint)LobeType::DiffuseReflection;

        if (min(wi.z, wo.z) < kMinCosTheta)
        {
            weight = float3(0,0,0);
            lobeP = 0.0;
            return false;
        }

        weight = albedo;
        lobeP = 1.0;
        return true;
    }

    float evalPdf(const float3 wi, const float3 wo)
    {
        if (min(wi.z, wo.z) < kMinCosTheta) return 0.f;

        return M_1_PI * wo.z;
    }
};

/** Disney's diffuse reflection.
    Based on https://blog.selfshadow.com/publications/s2012-shading-course/burley/s2012_pbs_disney_brdf_notes_v3.pdf
*/
struct DiffuseReflectionDisney // : IBxDF
{
    float3 albedo;          ///< Diffuse albedo.
    float roughness;        ///< Roughness before remapping.

    float3 eval(const float3 wi, const float3 wo)
    {
        if (min(wi.z, wo.z) < kMinCosTheta) return float3(0,0,0);

        return evalWeight(wi, wo) * M_1_PI * wo.z;
    }

    bool sample(const float3 wi, out float3 wo, out float pdf, out float3 weight, out uint lobe, out float lobeP, float3 preGeneratedSample)
    {
        wo = sample_cosine_hemisphere_concentric(preGeneratedSample.xy, pdf);
        lobe = (uint)LobeType::DiffuseReflection;

        if (min(wi.z, wo.z) < kMinCosTheta)
        {
            weight = float3(0,0,0);
            lobeP = 0.0;
            return false;
        }

        weight = evalWeight(wi, wo);
        lobeP = 1.0;
        return true;
    }

    float evalPdf(const float3 wi, const float3 wo)
    {
        if (min(wi.z, wo.z) < kMinCosTheta) return 0.f;

        return M_1_PI * wo.z;
    }

    // private

    // Returns f(wi, wo) * pi.
    float3 evalWeight(float3 wi, float3 wo)
    {
        float3 h = normalize(wi + wo);
        float woDotH = dot(wo, h);
        float fd90 = 0.5f + 2.f * woDotH * woDotH * roughness;
        float fd0 = 1.f;
        float wiScatter = evalFresnelSchlick(fd0, fd90, wi.z);
        float woScatter = evalFresnelSchlick(fd0, fd90, wo.z);
        return albedo * wiScatter * woScatter;
    }
};

/** Frostbites's diffuse reflection.
    This is Disney's diffuse BRDF with an ad-hoc normalization factor to ensure energy conservation.
    Based on https://seblagarde.files.wordpress.com/2015/07/course_notes_moving_frostbite_to_pbr_v32.pdf
*/
struct DiffuseReflectionFrostbite // : IBxDF
{
    float3 albedo;          ///< Diffuse albedo.
    float roughness;        ///< Roughness before remapping.

    float3 eval(const float3 wi, const float3 wo)
    {
        if (min(wi.z, wo.z) < kMinCosTheta) return float3(0,0,0);

        return evalWeight(wi, wo) * M_1_PI * wo.z;
    }

    bool sample(const float3 wi, out float3 wo, out float pdf, out float3 weight, out uint lobe, out float lobeP, float3 preGeneratedSample)
    {
        wo = sample_cosine_hemisphere_concentric(preGeneratedSample.xy, pdf);
        lobe = (uint)LobeType::DiffuseReflection;

        if (min(wi.z, wo.z) < kMinCosTheta)
        {
            weight = float3(0,0,0);
            lobeP = 0.0;
            return false;
        }

        weight = evalWeight(wi, wo);
        lobeP = 1.0;
        return true;
    }

    float evalPdf(const float3 wi, const float3 wo)
    {
        if (min(wi.z, wo.z) < kMinCosTheta) return 0.f;

        return M_1_PI * wo.z;
    }

    // private

    // Returns f(wi, wo) * pi.
    float3 evalWeight(float3 wi, float3 wo)
    {
        float3 h = normalize(wi + wo);
        float woDotH = dot(wo, h);
        float energyBias = lerp(0.f, 0.5f, roughness);
        float energyFactor = lerp(1.f, 1.f / 1.51f, roughness);
        float fd90 = energyBias + 2.f * woDotH * woDotH * roughness;
        float fd0 = 1.f;
        float wiScatter = evalFresnelSchlick(fd0, fd90, wi.z);
        float woScatter = evalFresnelSchlick(fd0, fd90, wo.z);
        return albedo * wiScatter * woScatter * energyFactor;
    }
};

/** Lambertian diffuse transmission.
*/
struct DiffuseTransmissionLambert // : IBxDF
{
    float3 albedo;  ///< Diffuse albedo.

    float3 eval(const float3 wi, const float3 wo)
    {
        if (min(wi.z, -wo.z) < kMinCosTheta) return float3(0,0,0);

        return M_1_PI * albedo * -wo.z;
    }

    bool sample(const float3 wi, out float3 wo, out float pdf, out float3 weight, out uint lobe, out float lobeP, float3 preGeneratedSample)
    {
        wo = sample_cosine_hemisphere_concentric(preGeneratedSample.xy, pdf);
        wo.z = -wo.z;
        lobe = (uint)LobeType::DiffuseTransmission;

        if (min(wi.z, -wo.z) < kMinCosTheta)
        {
            weight = float3(0,0,0);
            lobeP = 0.0;
            return false;
        }

        weight = albedo;
        lobeP = 1.0;
        return true;
    }

    float evalPdf(const float3 wi, const float3 wo)
    {
        if (min(wi.z, -wo.z) < kMinCosTheta) return 0.f;

        return M_1_PI * -wo.z;
    }
};

/** Specular reflection using microfacets.
*/
struct SpecularReflectionMicrofacet // : IBxDF
{
    float3 albedo;      ///< Specular albedo.
    float alpha;        ///< GGX width parameter.
    uint activeLobes;   ///< BSDF lobes to include for sampling and evaluation. See LobeType.hlsli.

    bool hasLobe(LobeType lobe) { return (activeLobes & (uint)lobe) != 0; }

    float3 eval(const float3 wi, const float3 wo)
    {
        if (min(wi.z, wo.z) < kMinCosTheta) return float3(0,0,0);

#if EnableDeltaBSDF
        // Handle delta reflection.
        if (alpha == 0.f) return float3(0,0,0);
#endif

        if (!hasLobe(LobeType::SpecularReflection)) return float3(0,0,0);

        float3 h = normalize(wi + wo);
        float wiDotH = dot(wi, h);

        float D = evalNdfGGX(alpha, h.z);
#if SpecularMaskingFunction == SpecularMaskingFunctionSmithGGXSeparable
        float G = evalMaskingSmithGGXSeparable(alpha, wi.z, wo.z);
#elif SpecularMaskingFunction == SpecularMaskingFunctionSmithGGXCorrelated
        float G = evalMaskingSmithGGXCorrelated(alpha, wi.z, wo.z);
#endif
        float3 F = evalFresnelSchlick(albedo, 1.f, wiDotH);
        return F * D * G * 0.25f / wi.z;
    }

    bool sample(const float3 wi, out float3 wo, out float pdf, out float3 weight, out uint lobe, out float lobeP, float3 preGeneratedSample)
    {
        // Default initialization to avoid divergence at returns.
        wo = float3(0,0,0);
        weight = float3(0,0,0);
        pdf = 0.f;
        lobe = (uint)LobeType::SpecularReflection;
        lobeP = 1.0;

        if (wi.z < kMinCosTheta) return false;

#if EnableDeltaBSDF
        // Handle delta reflection.
        if (alpha == 0.f)
        {
            if (!hasLobe(LobeType::DeltaReflection)) return false;

            wo = float3(-wi.x, -wi.y, wi.z);
            pdf = 0.f;
            weight = evalFresnelSchlick(albedo, 1.f, wi.z);
            lobe = (uint)LobeType::DeltaReflection;
            return true;
        }
#endif

        if (!hasLobe(LobeType::SpecularReflection)) return false;

        // Sample the GGX distribution to find a microfacet normal (half vector).
#if EnableVNDFSampling
        float3 h = sampleGGX_VNDF(alpha, wi, preGeneratedSample.xy, pdf);    // pdf = G1(wi) * D(h) * max(0,dot(wi,h)) / wi.z
#else
        float3 h = sampleGGX_NDF(alpha, preGeneratedSample.xy, pdf);         // pdf = D(h) * h.z
#endif

        // Reflect the incident direction to find the outgoing direction.
        float wiDotH = dot(wi, h);
        wo = 2.f * wiDotH * h - wi;
        if (wo.z < kMinCosTheta) return false;

#if ExplicitSampleWeights
        // For testing.
        pdf = evalPdf(wi, wo);
        weight = eval(wi, wo) / pdf;
        lobe = (uint)LobeType::SpecularReflection;
        return true;
#endif

#if SpecularMaskingFunction == SpecularMaskingFunctionSmithGGXSeparable
        float G = evalMaskingSmithGGXSeparable(alpha, wi.z, wo.z);
        float GOverG1wo = evalG1GGX(alpha * alpha, wo.z);
#elif SpecularMaskingFunction == SpecularMaskingFunctionSmithGGXCorrelated
        float G = evalMaskingSmithGGXCorrelated(alpha, wi.z, wo.z);
        float GOverG1wo = G * (1.f + evalLambdaGGX(alpha * alpha, wi.z));
#endif
        float3 F = evalFresnelSchlick(albedo, 1.f, wiDotH);

        pdf /= (4.f * wiDotH); // Jacobian of the reflection operator.
#if EnableVNDFSampling
        weight = F * GOverG1wo;
#else
        weight = F * G * wiDotH / (wi.z * h.z);
#endif
        lobe = (uint)LobeType::SpecularReflection;
        return true;
    }

    float evalPdf(const float3 wi, const float3 wo)
    {
        if (min(wi.z, wo.z) < kMinCosTheta) return 0.f;

#if EnableDeltaBSDF
        // Handle delta reflection.
        if (alpha == 0.f) return 0.f;
#endif

        if (!hasLobe(LobeType::SpecularReflection)) return 0.f;

        float3 h = normalize(wi + wo);
        float wiDotH = dot(wi, h);
#if EnableVNDFSampling
        float pdf = evalPdfGGX_VNDF(alpha, wi, h);
#else
        float pdf = evalPdfGGX_NDF(alpha, h.z);
#endif
        return pdf / (4.f * wiDotH);
    }
};

/** Specular reflection and transmission using microfacets.
*/
struct SpecularReflectionTransmissionMicrofacet// : IBxDF
{
    float3 transmissionAlbedo;  ///< Transmission albedo.
    float alpha;                ///< GGX width parameter.
    float eta;                  ///< Relative index of refraction (etaI / etaT).
    uint activeLobes;           ///< BSDF lobes to include for sampling and evaluation. See LobeType.hlsli.

    bool hasLobe(LobeType lobe) { return (activeLobes & (uint)lobe) != 0; }

    float3 eval(const float3 wi, const float3 wo)
    {
        if (min(wi.z, abs(wo.z)) < kMinCosTheta) return float3(0,0,0);

#if EnableDeltaBSDF
        // Handle delta reflection/transmission.
        if (alpha == 0.f) return float3(0,0,0);
#endif

        const bool hasReflection = hasLobe(LobeType::SpecularReflection);
        const bool hasTransmission = hasLobe(LobeType::SpecularTransmission);
        const bool isReflection = wo.z > 0.f;
        if ((isReflection && !hasReflection) || (!isReflection && !hasTransmission)) return float3(0,0,0);

        // Compute half-vector and make sure it's in the upper hemisphere.
        float3 h = normalize(wo + wi * (isReflection ? 1.f : eta));
        h *= float(sign(h.z));

        float wiDotH = dot(wi, h);
        float woDotH = dot(wo, h);

        float D = evalNdfGGX(alpha, h.z);
#if SpecularMaskingFunction == SpecularMaskingFunctionSmithGGXSeparable
        float G = evalMaskingSmithGGXSeparable(alpha, wi.z, abs(wo.z));
#elif SpecularMaskingFunction == SpecularMaskingFunctionSmithGGXCorrelated
        float G = evalMaskingSmithGGXCorrelated(alpha, wi.z, abs(wo.z));
#endif
        float F = evalFresnelDielectric(eta, wiDotH);

        if (isReflection)
        {
            return F * D * G * 0.25f / wi.z;
        }
        else
        {
            float sqrtDenom = woDotH + eta * wiDotH;
            float t = eta * eta * wiDotH * woDotH / (wi.z * sqrtDenom * sqrtDenom);
            return transmissionAlbedo * (1.f - F) * D * G * abs(t);
        }
    }

    bool sample(const float3 wi, out float3 wo, out float pdf, out float3 weight, out uint lobe, out float lobeP, float3 preGeneratedSample)
    {
        // Default initialization to avoid divergence at returns.
        wo = float3(0,0,0);
        weight = float3(0,0,0);
        pdf = 0.f;
        lobe = (uint)LobeType::SpecularReflection;
        lobeP = 1;

        if (wi.z < kMinCosTheta) return false;

        // Get a random number to decide what lobe to sample.
        float lobeSample = preGeneratedSample.z;

#if EnableDeltaBSDF
        // Handle delta reflection/transmission.
        if (alpha == 0.f)
        {
            const bool hasReflection = hasLobe(LobeType::DeltaReflection);
            const bool hasTransmission = hasLobe(LobeType::DeltaTransmission);
            if (!(hasReflection || hasTransmission)) return false;

            float cosThetaT;
            float F = evalFresnelDielectric(eta, wi.z, cosThetaT);

            bool isReflection = hasReflection;
            if (hasReflection && hasTransmission)
            {
                isReflection = lobeSample < F;
                lobeP = (isReflection)?(F):(1-F);
            }
            else if (hasTransmission && F == 1.f)
            {
                return false;
            }

            pdf = 0.f;
            weight = isReflection ? float3(1,1,1) : transmissionAlbedo;
            if (!(hasReflection && hasTransmission)) weight *= float3( (isReflection ? F : 1.f - F).xxx );
            wo = isReflection ? float3(-wi.x, -wi.y, wi.z) : float3(-wi.x * eta, -wi.y * eta, -cosThetaT);
            lobe = isReflection ? (uint)LobeType::DeltaReflection : (uint)LobeType::DeltaTransmission;

            if (abs(wo.z) < kMinCosTheta || (wo.z > 0.f != isReflection)) return false;

            return true;
        }
#endif

        const bool hasReflection = hasLobe(LobeType::SpecularReflection);
        const bool hasTransmission = hasLobe(LobeType::SpecularTransmission);
        if (!(hasReflection || hasTransmission)) return false;

        // Sample the GGX distribution of (visible) normals. This is our half vector.
#if EnableVNDFSampling
        float3 h = sampleGGX_VNDF(alpha, wi, preGeneratedSample.xy, pdf);    // pdf = G1(wi) * D(h) * max(0,dot(wi,h)) / wi.z
#else
        float3 h = sampleGGX_NDF(alpha, preGeneratedSample.xy, pdf);         // pdf = D(h) * h.z
#endif

        // Reflect/refract the incident direction to find the outgoing direction.
        float wiDotH = dot(wi, h);

        float cosThetaT;
        float F = evalFresnelDielectric(eta, wiDotH, cosThetaT);

        bool isReflection = hasReflection;
        if (hasReflection && hasTransmission)
        {
            isReflection = lobeSample < F;
        }
        else if (hasTransmission && F == 1.f)
        {
            return false;
        }

        wo = isReflection ?
            (2.f * wiDotH * h - wi) :
            ((eta * wiDotH - cosThetaT) * h - eta * wi);

        if (abs(wo.z) < kMinCosTheta || (wo.z > 0.f != isReflection)) return false;

        float woDotH = dot(wo, h);

        lobe = isReflection ? (uint)LobeType::SpecularReflection : (uint)LobeType::SpecularTransmission;

#if ExplicitSampleWeights
        // For testing.
        pdf = evalPdf(wi, wo);
        weight = pdf > 0.f ? eval(wi, wo) / pdf : float3(0.f);
        return true;
#endif

#if SpecularMaskingFunction == SpecularMaskingFunctionSmithGGXSeparable
        float G = evalMaskingSmithGGXSeparable(alpha, wi.z, abs(wo.z));
        float GOverG1wo = evalG1GGX(alpha * alpha, abs(wo.z));
#elif SpecularMaskingFunction == SpecularMaskingFunctionSmithGGXCorrelated
        float G = evalMaskingSmithGGXCorrelated(alpha, wi.z, abs(wo.z));
        float GOverG1wo = G * (1.f + evalLambdaGGX(alpha * alpha, wi.z));
#endif

#if EnableVNDFSampling
        weight = GOverG1wo;
#else
        weight = G * wiDotH / (wi.z * h.z);
#endif

        if (isReflection)
        {
            pdf /= 4.f * woDotH; // Jacobian of the reflection operator.
        }
        else
        {
            float sqrtDenom = woDotH + eta * wiDotH;
            float denom = sqrtDenom * sqrtDenom;
            pdf = (denom > 0.f) ? pdf * abs(woDotH) / denom : FLT_MAX; // Jacobian of the refraction operator.
            weight *= transmissionAlbedo * eta * eta;
        }

        if (hasReflection && hasTransmission)
        {
            pdf *= isReflection ? F : 1.f - F;
        }
        else
        {
            weight *= isReflection ? F : 1.f - F;
        }

        return true;
    }

    float evalPdf(const float3 wi, const float3 wo)
    {
        if (min(wi.z, abs(wo.z)) < kMinCosTheta) return 0.f;

#if EnableDeltaBSDF
        // Handle delta reflection/transmission.
        if (alpha == 0.f) return 0.f;
#endif

        bool isReflection = wo.z > 0.f;
        const bool hasReflection = hasLobe(LobeType::SpecularReflection);
        const bool hasTransmission = hasLobe(LobeType::SpecularTransmission);
        if ((isReflection && !hasReflection) || (!isReflection && !hasTransmission)) return 0.f;

        // Compute half-vector and make sure it's in the upper hemisphere.
        float3 h = normalize(wo + wi * (isReflection ? 1.f : eta));
        h *= float(sign(h.z));

        float wiDotH = dot(wi, h);
        float woDotH = dot(wo, h);

        float F = evalFresnelDielectric(eta, wiDotH);

#if EnableVNDFSampling
        float pdf = evalPdfGGX_VNDF(alpha, wi, h);
#else
        float pdf = evalPdfGGX_NDF(alpha, h.z);
#endif
        if (isReflection)
        {
            pdf /= 4.f * woDotH; // Jacobian of the reflection operator.
        }
        else
        {
            if (woDotH > 0.f) return 0.f;
            float sqrtDenom = woDotH + eta * wiDotH;
            float denom = sqrtDenom * sqrtDenom;
            pdf = (denom > 0.f) ? pdf * abs(woDotH) / denom : FLT_MAX; // Jacobian of the refraction operator.
        }

        if (hasReflection && hasTransmission)
        {
            pdf *= isReflection ? F : 1.f - F;
        }

        return pdf;
    }
};

// TODO: Reduce to 52B
/** BSDF parameters for the standard BSDF.
    These are needed for initializing a `FalcorBSDF` instance.
*/
struct StandardBSDFData
{
    float3 diffuse;                 ///< Diffuse albedo.
    float3 specular;                ///< Specular albedo.
    float roughness;                ///< This is the original roughness, before remapping.
    float metallic;                 ///< Metallic parameter, blends between dielectric and conducting BSDFs.
    float eta;                      ///< Relative index of refraction (incident IoR / transmissive IoR).
    float3 transmission;            ///< Transmission color.
    float diffuseTransmission;      ///< Diffuse transmission, blends between diffuse reflection and transmission lobes.
    float specularTransmission;     ///< Specular transmission, blends between opaque dielectric BRDF and specular transmissive BSDF.
    
    static StandardBSDFData make() 
    { 
        StandardBSDFData d;
        d.diffuse = 0;
        d.specular = 0;
        d.roughness = 0;
        d.metallic = 0;
        d.eta = 0;
        d.transmission = 0;
        d.diffuseTransmission = 0;
        d.specularTransmission = 0;
        return d;
    }

    static StandardBSDFData make(
        float3 diffuse,
        float3 specular,
        float roughness,
        float metallic,
        float eta,
        float3 transmission,
        float diffuseTransmission,
        float specularTransmission
    )
    {
        StandardBSDFData d;
        d.diffuse = diffuse;
        d.specular = specular;
        d.roughness = roughness;
        d.metallic = metallic;
        d.eta = eta;
        d.transmission = transmission;
        d.diffuseTransmission = diffuseTransmission;
        d.specularTransmission = specularTransmission;
        return d;
    }
};

/** Mixed BSDF used for the standard material in Falcor.

    This consists of a diffuse and specular BRDF.
    A specular BSDF is mixed in using the specularTransmission parameter.
*/
struct FalcorBSDF // : IBxDF
{
#if DiffuseBrdf == DiffuseBrdfLambert
    DiffuseReflectionLambert diffuseReflection;
#elif DiffuseBrdf == DiffuseBrdfDisney
    DiffuseReflectionDisney diffuseReflection;
#elif DiffuseBrdf == DiffuseBrdfFrostbite
    DiffuseReflectionFrostbite diffuseReflection;
#endif
    DiffuseTransmissionLambert diffuseTransmission;

    SpecularReflectionMicrofacet specularReflection;
    SpecularReflectionTransmissionMicrofacet specularReflectionTransmission;

    float diffTrans;                        ///< Mix between diffuse BRDF and diffuse BTDF.
    float specTrans;                        ///< Mix between dielectric BRDF and specular BSDF.

    float pDiffuseReflection;               ///< Probability for sampling the diffuse BRDF.
    float pDiffuseTransmission;             ///< Probability for sampling the diffuse BTDF.
    float pSpecularReflection;              ///< Probability for sampling the specular BRDF.
    float pSpecularReflectionTransmission;  ///< Probability for sampling the specular BSDF.

    bool psdExclude; // disable PSD

    /** Initialize a new instance.
        \param[in] sd Shading data.
        \param[in] data BSDF parameters.
    */
    void __init(
        const MaterialHeader mtl,
        float3 N,
        float3 V,
        const StandardBSDFData data)
    {
        // TODO: Currently specular reflection and transmission lobes are not properly separated.
        // This leads to incorrect behaviour if only the specular reflection or transmission lobe is selected.
        // Things work fine as long as both or none are selected.

        // Use square root if we can assume the shaded object is intersected twice.
        float3 transmissionAlbedo = mtl.isThinSurface() ? data.transmission : sqrt(data.transmission);

        // Setup lobes.
        diffuseReflection.albedo = data.diffuse;
#if DiffuseBrdf != DiffuseBrdfLambert
        diffuseReflection.roughness = data.roughness;
#endif
        diffuseTransmission.albedo = transmissionAlbedo;

        // Compute GGX alpha.
        float alpha = data.roughness * data.roughness;
#if EnableDeltaBSDF
        // Alpha below min alpha value means using delta reflection/transmission.
        if (alpha < kMinGGXAlpha) alpha = 0.f;
#else
        alpha = max(alpha, kMinGGXAlpha);
#endif
        const uint activeLobes = mtl.getActiveLobes();

        psdExclude = mtl.isPSDExclude();

        specularReflection.albedo = data.specular;
        specularReflection.alpha = alpha;
        specularReflection.activeLobes = activeLobes;

        specularReflectionTransmission.transmissionAlbedo = transmissionAlbedo;
        // Transmission through rough interface with same IoR on both sides is not well defined, switch to delta lobe instead.
        specularReflectionTransmission.alpha = data.eta == 1.f ? 0.f : alpha;
        specularReflectionTransmission.eta = data.eta;
        specularReflectionTransmission.activeLobes = activeLobes;

        diffTrans = data.diffuseTransmission;
        specTrans = data.specularTransmission;

        // Compute sampling weights.
        float metallicBRDF = data.metallic * (1.f - specTrans);
        float dielectricBSDF = (1.f - data.metallic) * (1.f - specTrans);
        float specularBSDF = specTrans;

        float diffuseWeight = luminance(data.diffuse);
        float specularWeight = luminance(evalFresnelSchlick(data.specular, 1.f, dot(V, N)));

        pDiffuseReflection = (activeLobes & (uint)LobeType::DiffuseReflection) ? diffuseWeight * dielectricBSDF * (1.f - diffTrans) : 0.f;
        pDiffuseTransmission = (activeLobes & (uint)LobeType::DiffuseTransmission) ? diffuseWeight * dielectricBSDF * diffTrans : 0.f;
        pSpecularReflection = (activeLobes & ((uint)LobeType::SpecularReflection | (uint)LobeType::DeltaReflection)) ? specularWeight * (metallicBRDF + dielectricBSDF) : 0.f;
        pSpecularReflectionTransmission = (activeLobes & ((uint)LobeType::SpecularReflection | (uint)LobeType::DeltaReflection | (uint)LobeType::SpecularTransmission | (uint)LobeType::DeltaTransmission)) ? specularBSDF : 0.f;

        float normFactor = pDiffuseReflection + pDiffuseTransmission + pSpecularReflection + pSpecularReflectionTransmission;
        if (normFactor > 0.f)
        {
            normFactor = 1.f / normFactor;
            pDiffuseReflection *= normFactor;
            pDiffuseTransmission *= normFactor;
            pSpecularReflection *= normFactor;
            pSpecularReflectionTransmission *= normFactor;
        }
    }
    
    /** Initialize a new instance.
    \param[in] sd Shading data.
    \param[in] data BSDF parameters.
*/
    void __init(const ShadingData shadingData, const StandardBSDFData data)
    {
        __init(shadingData.mtl, shadingData.V, shadingData.N, data);
    }

    static FalcorBSDF make( const ShadingData shadingData, const StandardBSDFData data )     { FalcorBSDF ret; ret.__init(shadingData, data); return ret; }

    static FalcorBSDF make(
        const MaterialHeader mtl,
        float3 N,
        float3 V, 
        const StandardBSDFData data) 
    { 
        FalcorBSDF ret;
        ret.__init(mtl, N, V, data); 
        return ret;
    }

    /** Returns the set of BSDF lobes.
        \param[in] data BSDF parameters.
        \return Returns a set of lobes (see LobeType.hlsli).
    */
    static uint getLobes(const StandardBSDFData data)
    {
#if EnableDeltaBSDF
        float alpha = data.roughness * data.roughness;
        bool isDelta = alpha < kMinGGXAlpha;
#else
        bool isDelta = false;
#endif
        float diffTrans = data.diffuseTransmission;
        float specTrans = data.specularTransmission;

        uint lobes = isDelta ? (uint)LobeType::DeltaReflection : (uint)LobeType::SpecularReflection;
        if (any(data.diffuse > 0.f) && specTrans < 1.f)
        {
            if (diffTrans < 1.f) lobes |= (uint)LobeType::DiffuseReflection;
            if (diffTrans > 0.f) lobes |= (uint)LobeType::DiffuseTransmission;
        }
        if (specTrans > 0.f) lobes |= (isDelta ? (uint)LobeType::DeltaTransmission : (uint)LobeType::SpecularTransmission);

        return lobes;
    }

#if PTSDK_DIFFUSE_SPECULAR_SPLIT
    void eval(const float3 wi, const float3 wo, out float3 diffuse, out float3 specular)
    {
        diffuse = 0.f; specular = 0.f;
        if (pDiffuseReflection > 0.f) diffuse += (1.f - specTrans) * (1.f - diffTrans) * diffuseReflection.eval(wi, wo);
        if (pDiffuseTransmission > 0.f) diffuse += (1.f - specTrans) * diffTrans * diffuseTransmission.eval(wi, wo);
        if (pSpecularReflection > 0.f) specular += (1.f - specTrans) * specularReflection.eval(wi, wo);
        if (pSpecularReflectionTransmission > 0.f) specular += specTrans * (specularReflectionTransmission.eval(wi, wo));
    }
#else
    float3 eval(const float3 wi, const float3 wo)
    {
        float3 result = 0.f;
        if (pDiffuseReflection > 0.f) result += (1.f - specTrans) * (1.f - diffTrans) * diffuseReflection.eval(wi, wo);
        if (pDiffuseTransmission > 0.f) result += (1.f - specTrans) * diffTrans * diffuseTransmission.eval(wi, wo);
        if (pSpecularReflection > 0.f) result += (1.f - specTrans) * specularReflection.eval(wi, wo);
        if (pSpecularReflectionTransmission > 0.f) result += specTrans * (specularReflectionTransmission.eval(wi, wo));
        return result;
    }
#endif

    bool sample(const float3 wi, out float3 wo, out float pdf, out float3 weight, out uint lobe, out float lobeP, 
#if !RecycleSelectSamples
    float4 preGeneratedSample
#else
    float3 preGeneratedSample
#endif
    )
    {
        // Default initialization to avoid divergence at returns.
        wo = float3(0,0,0);
        weight = float3(0,0,0);
        pdf = 0.f;
        lobe = (uint)LobeType::DiffuseReflection;
        lobeP = 0.0;

        bool valid = false;
        float uSelect = preGeneratedSample.z;
#if !RecycleSelectSamples
        preGeneratedSample.z = preGeneratedSample.w;    // we've used .z for uSelect, shift left, .w is now unusable
#endif

        // Note: The commented-out pdf contributions below are always zero, so no need to compute them.

        if (uSelect < pDiffuseReflection)
        {
#if RecycleSelectSamples
            preGeneratedSample.z = clamp(uSelect / pDiffuseReflection, 0, OneMinusEpsilon); // note, this gets compiled out because bsdf below does not need .z, however it has been tested and can be used in case of a new bsdf that might require it
#endif
            
            valid = diffuseReflection.sample(wi, wo, pdf, weight, lobe, lobeP, preGeneratedSample.xyz);
            weight /= pDiffuseReflection;
            weight *= (1.f - specTrans) * (1.f - diffTrans);
            pdf *= pDiffuseReflection;
            lobeP *= pDiffuseReflection;
            // if (pDiffuseTransmission > 0.f) pdf += pDiffuseTransmission * diffuseTransmission.evalPdf(wi, wo);
            if (pSpecularReflection > 0.f) pdf += pSpecularReflection * specularReflection.evalPdf(wi, wo);
            if (pSpecularReflectionTransmission > 0.f) pdf += pSpecularReflectionTransmission * specularReflectionTransmission.evalPdf(wi, wo);
        }
        else if (uSelect < pDiffuseReflection + pDiffuseTransmission)
        {
            valid = diffuseTransmission.sample(wi, wo, pdf, weight, lobe, lobeP, preGeneratedSample.xyz);
            weight /= pDiffuseTransmission;
            weight *= (1.f - specTrans) * diffTrans;
            pdf *= pDiffuseTransmission;
            lobeP *= pDiffuseTransmission;
            // if (pDiffuseReflection > 0.f) pdf += pDiffuseReflection * diffuseReflection.evalPdf(wi, wo);
            // if (pSpecularReflection > 0.f) pdf += pSpecularReflection * specularReflection.evalPdf(wi, wo);
            if (pSpecularReflectionTransmission > 0.f) pdf += pSpecularReflectionTransmission * specularReflectionTransmission.evalPdf(wi, wo);
        }
        else if (uSelect < pDiffuseReflection + pDiffuseTransmission + pSpecularReflection)
        {
#if RecycleSelectSamples
            preGeneratedSample.z = clamp((uSelect - (pDiffuseReflection + pDiffuseTransmission))/pSpecularReflection, 0, OneMinusEpsilon); // note, this gets compiled out because bsdf below does not need .z, however it has been tested and can be used in case of a new bsdf that might require it
#endif

            valid = specularReflection.sample(wi, wo, pdf, weight, lobe, lobeP, preGeneratedSample.xyz);
            weight /= pSpecularReflection;
            weight *= (1.f - specTrans);
            pdf *= pSpecularReflection;
            lobeP *= pSpecularReflection;
            if (pDiffuseReflection > 0.f) pdf += pDiffuseReflection * diffuseReflection.evalPdf(wi, wo);
            // if (pDiffuseTransmission > 0.f) pdf += pDiffuseTransmission * diffuseTransmission.evalPdf(wi, wo);
            if (pSpecularReflectionTransmission > 0.f) pdf += pSpecularReflectionTransmission * specularReflectionTransmission.evalPdf(wi, wo);
        }
        else if (pSpecularReflectionTransmission > 0.f)
        {
#if RecycleSelectSamples
            preGeneratedSample.z = clamp((uSelect - (pDiffuseReflection + pDiffuseTransmission + pSpecularReflection))/pSpecularReflectionTransmission, 0, OneMinusEpsilon);
#endif

            valid = specularReflectionTransmission.sample(wi, wo, pdf, weight, lobe, lobeP, preGeneratedSample.xyz);
            weight /= pSpecularReflectionTransmission;
            weight *= specTrans;
            pdf *= pSpecularReflectionTransmission;
            lobeP *= pSpecularReflectionTransmission;
            if (pDiffuseReflection > 0.f) pdf += pDiffuseReflection * diffuseReflection.evalPdf(wi, wo);
            if (pDiffuseTransmission > 0.f) pdf += pDiffuseTransmission * diffuseTransmission.evalPdf(wi, wo);
            if (pSpecularReflection > 0.f) pdf += pSpecularReflection * specularReflection.evalPdf(wi, wo);
        }

        if( !valid || (lobe & (uint)LobeType::Delta) != 0 )
            pdf = 0.0;

        return valid;
    }

    float evalPdf(const float3 wi, const float3 wo)
    {
        float pdf = 0.f;
        if (pDiffuseReflection > 0.f) pdf += pDiffuseReflection * diffuseReflection.evalPdf(wi, wo);
        if (pDiffuseTransmission > 0.f) pdf += pDiffuseTransmission * diffuseTransmission.evalPdf(wi, wo);
        if (pSpecularReflection > 0.f) pdf += pSpecularReflection * specularReflection.evalPdf(wi, wo);
        if (pSpecularReflectionTransmission > 0.f) pdf += pSpecularReflectionTransmission * specularReflectionTransmission.evalPdf(wi, wo);
        return pdf;
    }

    void evalDeltaLobes(const float3 wi, inout DeltaLobe deltaLobes[cMaxDeltaLobes], inout int deltaLobeCount, inout float nonDeltaPart)  // wi is in local space
    {
        deltaLobeCount = 2;             // currently - will be 1 more if we add clear coat :)
        for (int i = 0; i < deltaLobeCount; i++)
            deltaLobes[i] = DeltaLobe::make(); // init to zero
#if EnableDeltaBSDF == 0
#error not sure what to do here in this case
        return info;
#endif

        nonDeltaPart = pDiffuseReflection+pDiffuseTransmission;
        if ( specularReflection.alpha > 0 ) // if roughness > 0, lobe is not delta
            nonDeltaPart += pSpecularReflection;
        if ( specularReflectionTransmission.alpha > 0 ) // if roughness > 0, lobe is not delta
            nonDeltaPart += pSpecularReflectionTransmission;

        // no spec reflection or transmission? delta lobes are zero (we can just return, already initialized to 0)!
        if ( (pSpecularReflection+pSpecularReflectionTransmission) == 0 || psdExclude )    
            return;

        // note, deltaReflection here represents both this.specularReflection and this.specularReflectionTransmission's
        DeltaLobe deltaReflection, deltaTransmission;
        deltaReflection = deltaTransmission = DeltaLobe::make(); // init to zero
        deltaReflection.transmission    = false;
        deltaTransmission.transmission  = true;

        deltaReflection.Wo  = float3(-wi.x, -wi.y, wi.z);

        if (specularReflection.alpha == 0 && specularReflection.hasLobe(LobeType::DeltaReflection))
        {
            deltaReflection.probability = pSpecularReflection;

            // re-compute correct thp for all channels (using float3 version of evalFresnelSchlick!) but then take out the portion that is handled by specularReflectionTransmission below!
            deltaReflection.thp = (1-pSpecularReflectionTransmission)*evalFresnelSchlick(specularReflection.albedo, 1.f, wi.z);
        }

        // Handle delta reflection/transmission.
        if (specularReflectionTransmission.alpha == 0.f)
        {
            const bool hasReflection = specularReflectionTransmission.hasLobe(LobeType::DeltaReflection);
            const bool hasTransmission = specularReflectionTransmission.hasLobe(LobeType::DeltaTransmission);
            if (hasReflection || hasTransmission)
            {
                float cosThetaT;
                float F = evalFresnelDielectric(specularReflectionTransmission.eta, wi.z, cosThetaT);

                if (hasReflection)
                {
                    float localProbability = pSpecularReflectionTransmission * F;
                    float3 weight = float3(1,1,1) * localProbability;
                    deltaReflection.thp += weight;
                    deltaReflection.probability += localProbability;
                }

                if (hasTransmission)
                {
                    float localProbability = pSpecularReflectionTransmission * (1.0-F);
                    float3 weight = specularReflectionTransmission.transmissionAlbedo * localProbability;
                    deltaTransmission.Wo  = float3(-wi.x * specularReflectionTransmission.eta, -wi.y * specularReflectionTransmission.eta, -cosThetaT);
                    deltaTransmission.thp = weight;
                    deltaTransmission.probability = localProbability;
                }

                // 
                // if (abs(wo.z) < kMinCosTheta || (wo.z > 0.f != isReflection)) return false;
            }
        }

        // Lobes are by convention in this order, and the index must match BSDFSample::getDeltaLobeIndex() as well as the UI.
        // When we add clearcoat it goes after deltaReflection and so on.
        deltaLobes[0] = deltaTransmission;
        deltaLobes[1] = deltaReflection;
    }
};

#endif // __BxDF_HLSLI__