/*
* Copyright (c) 2023, NVIDIA CORPORATION.  All rights reserved.
*
* NVIDIA CORPORATION and its licensors retain all intellectual property
* and proprietary rights in and to this software, related documentation
* and any modifications thereto.  Any use, reproduction, disclosure or
* distribution of this software and related documentation without an express
* license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#ifndef __SCENE_TYPES_HLSLI__ // using instead of "#pragma once" due to https://github.com/microsoft/DirectXShaderCompiler/issues/3943
#define __SCENE_TYPES_HLSLI__

#include "../Config.h"    

#include "SceneDefines.hlsli"

#if defined(__cplusplus)
#error fix below first
// due to HLSL bug in one of the currently used compilers, it will still try to include these even though they're #ifdef-ed out
// #include "Utils/Math/PackedFormats.h"
#else
#include "../Utils/Math/PackedFormats.hlsli"
#endif

#ifdef OV_BRIDGE
struct GeometryInstanceID
{
    uint instanceID;
    uint geometryByteOffset;
};
#elif 1 // pt_sdk<->donut mod - this is really engine dependent so keep as 2 separate uint-s for now for simplicity
struct GeometryInstanceID
{
    uint data;
    static GeometryInstanceID   make( uint instanceIndex, uint geometryIndex )          { GeometryInstanceID ret; ret.data = (geometryIndex << 16) | instanceIndex; return ret; }
    uint                        getInstanceIndex( )                                     { return data & 0xFFFF; }
    uint                        getGeometryIndex( )                                     { return data >> 16; }
};
#else // !OV_BRIDGE
/** Geometry instance ID.
    This uniquely identifies a geometry instance in the scene.
    All instances are sequentially indexed, with mesh instances first.
    This may change in the future, but a lot of existing code relies on it.
*/
struct GeometryInstanceID
{
    uint index;             ///< Global instance index. This is computed as InstanceID() + GeometryIndex().

#if !defined(__cplusplus)
    /** Construct a geometry instance ID.
        \param[in] instanceID The DXR InstanceID() system value.
        \param[in] geometryIndex The DXR GeometryIndex() system value.
    */
    void __init(uint instanceID, uint geometryIndex)
    {
        index = instanceID + geometryIndex;
    }
    static GeometryInstanceID make(uint instanceID, uint geometryIndex)  { GeometryInstanceID ret; ret.__init(instanceID, geometryIndex); return ret; }
#endif
};
#endif // OV_BRIDGE

/** Geometry types in the scene.
*/
enum class GeometryType : uint32_t
{
    None                    = GEOMETRY_TYPE_NONE,
    TriangleMesh            = GEOMETRY_TYPE_TRIANGLE_MESH,
    DisplacedTriangleMesh   = GEOMETRY_TYPE_DISPLACED_TRIANGLE_MESH,
    Curve                   = GEOMETRY_TYPE_CURVE,
    SDFGrid                 = GEOMETRY_TYPE_SDF_GRID,
    Custom                  = GEOMETRY_TYPE_CUSTOM,

    Count
};

/** Flags indicating what geometry types exist in the scene.
*/
enum class GeometryTypeFlags : uint32_t
{
    TriangleMesh            = (1u << GEOMETRY_TYPE_TRIANGLE_MESH),
    DisplacedTriangleMesh   = (1u << GEOMETRY_TYPE_DISPLACED_TRIANGLE_MESH),
    Curve                   = (1u << GEOMETRY_TYPE_CURVE),
    SDFGrid                 = (1u << GEOMETRY_TYPE_SDF_GRID),
    Custom                  = (1u << GEOMETRY_TYPE_CUSTOM),
};

#if defined(__cplusplus)
FALCOR_ENUM_CLASS_OPERATORS(GeometryTypeFlags);
#endif

enum class GeometryInstanceFlags : uint32_t
{
    None = 0x0,

    // Mesh flags.
    Use16BitIndices = 0x1,      ///< Indices are in 16-bit format. The default is 32-bit.
    IsDynamic = 0x2,            ///< Mesh is dynamic, either through skinning or vertex animations.
    TransformFlipped = 0x4,     ///< Instance transform flips the coordinate system handedness. TODO: Deprecate this flag if we need an extra bit.
    IsObjectFrontFaceCW = 0x8,  ///< Front-facing side has clockwise winding in object space. Note that the winding in world space may be flipped due to the instance transform.
    IsWorldFrontFaceCW = 0x10,  ///< Front-facing side has clockwise winding in world space. This is the combination of the mesh winding and instance transform handedness.
};

struct GeometryInstanceData
{
    static const uint kTypeBits = 3;
    static const uint kTypeOffset = 32 - kTypeBits;

    uint flags;             ///< Upper kTypeBits bits are reserved for storing the type.
    uint globalMatrixID;
    uint materialID;
    uint geometryID;

    uint vbOffset;          ///< Offset into vertex buffer.
    uint ibOffset;          ///< Offset into index buffer, or zero if non-indexed.

    uint instanceIndex;     ///< InstanceIndex in TLAS.
    uint geometryIndex;     ///< GeometryIndex in BLAS.

#if defined(__cplusplus)
    GeometryInstanceData() = default;

    GeometryInstanceData(GeometryType type)
        : flags((uint32_t)type << kTypeOffset)
    {}
#endif

    GeometryType getType() CONST_FUNCTION
    {
        return (GeometryType)(flags >> kTypeOffset);
    }

    bool isDynamic() CONST_FUNCTION
    {
        return (flags & (uint)GeometryInstanceFlags::IsDynamic) != 0;
    }

    bool isWorldFrontFaceCW() CONST_FUNCTION
    {
        return (flags & (uint)GeometryInstanceFlags::IsWorldFrontFaceCW) != 0;
    }
};

enum class MeshFlags : uint32_t
{
    None = 0x0,
    Use16BitIndices = 0x1,  ///< Indices are in 16-bit format. The default is 32-bit.
    IsSkinned = 0x2,        ///< Mesh is skinned and has corresponding vertex data.
    IsFrontFaceCW = 0x4,    ///< Front-facing side has clockwise winding in object space. Note that the winding in world space may be flipped due to the instance transform.
    IsDisplaced = 0x8,      ///< Mesh has displacement map.
    IsAnimated = 0x10,      ///< Mesh is affected by vertex-animations.
};

/** Mesh data stored in 64B.
*/
struct MeshDesc
{
    uint vbOffset;          ///< Offset into global vertex buffer.
    uint ibOffset;          ///< Offset into global index buffer, or zero if non-indexed.
    uint vertexCount;       ///< Vertex count.
    uint indexCount;        ///< Index count, or zero if non-indexed.
    uint skinningVbOffset;  ///< Offset into skinning data buffer, or zero if no skinning data.
    uint prevVbOffset;      ///< Offset into previous vertex data buffer, or zero if neither skinned or animated.
    uint materialID;        ///< Material ID.
    uint flags;             ///< See MeshFlags.

    uint getTriangleCount() CONST_FUNCTION
    {
        return (indexCount > 0 ? indexCount : vertexCount) / 3;
    }

    bool use16BitIndices() CONST_FUNCTION
    {
        return (flags & (uint)MeshFlags::Use16BitIndices) != 0;
    }

    bool isSkinned() CONST_FUNCTION
    {
        return (flags & (uint)MeshFlags::IsSkinned) != 0;
    }

    bool isAnimated() CONST_FUNCTION
    {
        return (flags & (uint)MeshFlags::IsAnimated) != 0;
    }

    bool isDynamic() CONST_FUNCTION
    {
        return isSkinned() || isAnimated();
    }

    bool isFrontFaceCW() CONST_FUNCTION
    {
        return (flags & (uint)MeshFlags::IsFrontFaceCW) != 0;
    }

    bool isDisplaced() CONST_FUNCTION
    {
        return (flags & (uint)MeshFlags::IsDisplaced) != 0;
    }
};

struct StaticVertexData
{
    float3 position;    ///< Position.
    float3 normal;      ///< Shading normal.
    float4 tangent;     ///< Shading tangent. The bitangent is computed: cross(normal, tangent.xyz) * tangent.w. NOTE: The tangent is *only* valid when tangent.w != 0.
    float2 texCrd;      ///< Texture coordinates.
    float curveRadius;  ///< Curve cross-sectional radius. Valid only for geometry generated from curves.
};

/** Vertex data packed into 32B for aligned access.
*/
struct PackedStaticVertexData
{
    float3 position;
    float3 packedNormalTangentCurveRadius;
    float2 texCrd;

#if defined(__cplusplus)
    PackedStaticVertexData() = default;
    PackedStaticVertexData(const StaticVertexData& v) { pack(v); }
    void pack(const StaticVertexData& v)
    {
        position = v.position;
        texCrd = v.texCrd;

        float packedTangentSignCurveRadius = v.tangent.w;

        if (v.curveRadius > 0.f)
        {
            // This is safe because if v.curveRadius > 0 then v.tangent.w != 0 (curves always have valid tangents).
            FALCOR_ASSERT(v.tangent.w != 0.f);
            packedTangentSignCurveRadius *= v.curveRadius;
        }

        packedNormalTangentCurveRadius.x = asfloat(glm::packHalf2x16({ v.normal.x, v.normal.y }));
        packedNormalTangentCurveRadius.y = asfloat(glm::packHalf2x16({ v.normal.z, packedTangentSignCurveRadius }));
        packedNormalTangentCurveRadius.z = asfloat(encodeNormal2x16(v.tangent.xyz));
    }

#else // !defined(__cplusplus)
    SETTER_DECL void pack(const StaticVertexData v)
    {
        position = v.position;
        texCrd = v.texCrd;

        uint3 n = f32tof16(v.normal);

        float packedTangentSignCurveRadius = v.tangent.w;
        // This is safe because if v.curveRadius > 0 then v.tangent.w != 0 (curves always have valid tangents).
        if (v.curveRadius > 0.f) packedTangentSignCurveRadius *= v.curveRadius;
        uint t_w = f32tof16(packedTangentSignCurveRadius);

        packedNormalTangentCurveRadius.x = asfloat((n.y << 16) | n.x);
        packedNormalTangentCurveRadius.y = asfloat((t_w << 16) | n.z);
        packedNormalTangentCurveRadius.z = asfloat(encodeNormal2x16(v.tangent.xyz));
    }

    StaticVertexData unpack()
    {
        StaticVertexData v;
        v.position = position;
        v.texCrd = texCrd;

        v.normal.x = f16tof32(asuint(packedNormalTangentCurveRadius.x) & 0xffff);
        v.normal.y = f16tof32(asuint(packedNormalTangentCurveRadius.x) >> 16);
        v.normal.z = f16tof32(asuint(packedNormalTangentCurveRadius.y) & 0xffff);
        v.normal = normalize(v.normal);

        v.tangent.xyz = decodeNormal2x16(asuint(packedNormalTangentCurveRadius.z));
        float packedTangentSignCurveRadius = f16tof32(asuint(packedNormalTangentCurveRadius.y) >> 16);
        v.tangent.w = sign(packedTangentSignCurveRadius);

        v.curveRadius = abs(packedTangentSignCurveRadius);

        return v;
    }
#endif
};

struct PrevVertexData
{
    float3 position;
};

struct SkinningVertexData
{
    uint4 boneID;
    float4 boneWeight;
    uint staticIndex;       ///< The index in the static vertex buffer.
    uint bindMatrixID;
    uint skeletonMatrixID;
};

/** Struct representing interpolated vertex attributes in world space.
    Note the tangent is not guaranteed to be orthogonal to the normal.
    The bitangent should be computed: cross(normal, tangent.xyz) * tangent.w.
    The tangent space is orthogonalized in prepareShadingData().
*/
struct VertexData
{
    float3 posW;            ///< Position in world space.
    float3 normalW;         ///< Shading normal in world space (normalized).
    float4 tangentW;        ///< Shading tangent in world space (normalized). The last component is guaranteed to be +-1.0 or zero if tangents are missing.
    float2 texC;            ///< Texture coordinate.
    float3 faceNormalW;     ///< Face normal in world space (normalized).
    float  curveRadius;     ///< Curve cross-sectional radius. Valid only for geometry generated from curves.
    float  coneTexLODValue; ///< Texture LOD data for cone tracing. This is zero, unless getVertexDataRayCones() is used.
};

struct CurveDesc
{
    uint vbOffset;      ///< Offset into global curve vertex buffer.
    uint ibOffset;      ///< Offset into global curve index buffer.
    uint vertexCount;   ///< Vertex count.
    uint indexCount;    ///< Index count.
    uint degree;        ///< Polynomial degree of curve; linear (1) by default.
    uint materialID;    ///< Material ID.

    uint getSegmentCount() CONST_FUNCTION
    {
        return indexCount;
    }
};

struct StaticCurveVertexData
{
    float3 position;    ///< Position.
    float radius;       ///< Radius of the sphere at curve ends.
    float2 texCrd;      ///< Texture coordinates.
};

struct DynamicCurveVertexData
{
    float3 position;    ///< Position.
};

/** Custom primitive data.
    The custom primitives are currently mapped 1:1 to the list of custom primitive AABBs.
*/
struct CustomPrimitiveDesc
{
    uint userID;        ///< User-defined ID that is specified during scene creation. This can be used to identify different sub-types of custom primitives.
    uint aabbOffset;    ///< Offset into list of procedural primitive AABBs.
};

END_NAMESPACE_FALCOR

#endif // __SCENE_TYPES_HLSLI__