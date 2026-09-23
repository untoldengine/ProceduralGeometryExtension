//
//  ProceduralGeometryExtensionRuntime.swift
//  ProceduralGeometryExtension
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CShaderTypes
import simd
import UntoldEngine

/// An `EngineExtension` that turns parametric control-point input into a renderable mesh on an
/// entity. The name is capability-agnostic on purpose (see the module-level doc comment); the
/// only capability implemented so far is tube generation (`TubeGeometryGenerator`).
///
/// Registration/entity-creation calls (`install`, `createTubeEntity`, the editing API) must run
/// on the same thread the rest of the engine's ECS registration calls run on — they call
/// straight through to `createEntity`/`setEntityMeshDirect`, which enforce that themselves.
/// `@unchecked Sendable` here matches the same pattern used by the engine's other
/// `EngineExtension` singletons (e.g. `PhysicsCoordinator`).
public final class ProceduralGeometryExtension: EngineExtension, @unchecked Sendable {
    public static let shared = ProceduralGeometryExtension()

    public let id = "com.untoldengine.extensions.proceduralGeometry"

    /// The `TubePathComponent.contentVersion` this extension last generated a mesh for, per
    /// owned entity. `update` compares this against each entity's live component every tick —
    /// an integer comparison, not a geometry diff — to catch changes made some other way than
    /// this extension's own editing calls (a scene load, or a script writing the component's
    /// fields directly).
    private var lastBuiltVersions: [EntityID: Int] = [:]

    private init() {}

    /// Registers this extension with the engine's non-rendering lifecycle registry, and
    /// registers `TubePathComponent` for scene persistence. Call once at app startup, before
    /// creating any tube entities.
    ///
    /// Scene save/load restores `TubePathComponent`'s fields (not a mesh — this only updates
    /// the component; the actual mesh gets (re)built the next time `update` runs, the same
    /// per-tick safety net that already catches any other out-of-band component change). This
    /// deliberately avoids the engine's generic `.procedural` scene-asset mechanism, which only
    /// recognizes a fixed set of primitive names and silently drops whatever parameters created
    /// them — using it here would mean a saved tube reloads as a unit cube.
    ///
    /// A merge closure is required, not optional: `encodeCustomComponent`'s decoder only
    /// persists decoded data back into the ECS when the merge closure mutates the existing
    /// component's fields in place. The default (no closure) path reassigns a local copy that's
    /// discarded when the decoder returns, so it never actually writes the decoded values back.
    public func install() {
        EngineExtensionRegistry.shared.register(self)
        encodeCustomComponent(type: TubePathComponent.self) { existing, decoded in
            existing.controlPoints = decoded.controlPoints
            existing.radius = decoded.radius
            existing.radialSegments = decoded.radialSegments
            existing.capStart = decoded.capStart
            existing.capEnd = decoded.capEnd
            existing.bendRadius = decoded.bendRadius
            existing.assetName = decoded.assetName
            existing.contentVersion = decoded.contentVersion
        }
    }

    /// Creates a new entity with a tube mesh swept along `controlPoints`, and a
    /// `TubePathComponent` recording the parameters that produced it.
    ///
    /// Returns `nil` (and creates nothing) if `TubeGeometryGenerator`/`Mesh.makeMesh` reject the
    /// input — e.g. fewer than two distinct control points, a non-positive radius, or fewer
    /// than three radial segments.
    @discardableResult
    public func createTubeEntity(
        controlPoints: [SIMD3<Float>],
        radius: Float,
        radialSegments: Int,
        capStart: Bool = false,
        capEnd: Bool = false,
        bendRadius: Float? = nil,
        name: String = "Tube"
    ) -> EntityID? {
        guard let geometry = TubeGeometryGenerator.generate(
            controlPoints: controlPoints,
            radius: radius,
            radialSegments: radialSegments,
            capStart: capStart,
            capEnd: capEnd,
            bendRadius: bendRadius
        ) else {
            return nil
        }

        let entityId = createEntity()
        setEntityName(entityId: entityId, name: name)

        registerComponent(entityId: entityId, componentType: TubePathComponent.self)
        guard let component = scene.get(component: TubePathComponent.self, for: entityId) else {
            destroyEntity(entityId: entityId)
            return nil
        }
        component.controlPoints = controlPoints
        component.radius = radius
        component.radialSegments = radialSegments
        component.capStart = capStart
        component.capEnd = capEnd
        component.bendRadius = bendRadius
        component.assetName = name
        component.contentVersion = 0

        guard rebuildMesh(entityId: entityId, component: component, geometry: geometry) else {
            destroyEntity(entityId: entityId)
            return nil
        }

        return entityId
    }

    /// Replaces the control-point path and updates the mesh. The common interactive-drag case —
    /// same point count, same radial segments, same caps — takes the in-place fast path (see
    /// `applyGeometryUpdate`); anything that changes vertex/index counts falls back to a full
    /// rebuild automatically.
    @discardableResult
    public func setControlPoints(entityId: EntityID, _ controlPoints: [SIMD3<Float>]) -> Bool {
        guard let component = scene.get(component: TubePathComponent.self, for: entityId) else { return false }
        component.controlPoints = controlPoints
        component.contentVersion += 1
        return applyGeometryUpdate(entityId: entityId, component: component)
    }

    /// Inserts a new control point at `index` (valid range `0...controlPoints.count`, i.e.
    /// inserting at `count` appends) and updates the mesh. A point-count change is a topology
    /// change, so this always takes the full-rebuild path.
    ///
    /// Returns `false` (no-op) if `index` is out of range or the entity has no `TubePathComponent`.
    @discardableResult
    public func insertControlPoint(entityId: EntityID, at index: Int, _ point: SIMD3<Float>) -> Bool {
        guard let component = scene.get(component: TubePathComponent.self, for: entityId),
              index >= 0, index <= component.controlPoints.count
        else {
            return false
        }
        component.controlPoints.insert(point, at: index)
        component.contentVersion += 1
        return applyGeometryUpdate(entityId: entityId, component: component)
    }

    /// Removes the control point at `index` and updates the mesh.
    ///
    /// Returns `false` (no-op, path left untouched) if `index` is out of range, or if removing
    /// it would drop the tube below 2 control points — `TubeGeometryGenerator` requires at
    /// least 2 to produce anything, so this is refused here rather than left to silently fail
    /// deeper in the pipeline.
    @discardableResult
    public func removeControlPoint(entityId: EntityID, at index: Int) -> Bool {
        guard let component = scene.get(component: TubePathComponent.self, for: entityId),
              index >= 0, index < component.controlPoints.count,
              component.controlPoints.count > 2
        else {
            return false
        }
        component.controlPoints.remove(at: index)
        component.contentVersion += 1
        return applyGeometryUpdate(entityId: entityId, component: component)
    }

    /// Changes the tube radius and updates the mesh (also eligible for the in-place fast path —
    /// it changes vertex positions, not vertex/index counts).
    @discardableResult
    public func setRadius(entityId: EntityID, _ radius: Float) -> Bool {
        guard let component = scene.get(component: TubePathComponent.self, for: entityId) else { return false }
        component.radius = radius
        component.contentVersion += 1
        return applyGeometryUpdate(entityId: entityId, component: component)
    }

    /// Sets (or clears, with `nil`) the corner-rounding radius. Whether this takes the fast path
    /// or a full rebuild is detected automatically, same as any other edit — going from unset to
    /// set (or back) changes vertex/index counts (sharp corners are a single point each, rounded
    /// ones expand to several), so that always rebuilds; changing an already-set radius to
    /// another value that rounds the same set of corners stays on the fast path. Note this is a
    /// global, once-per-tube setting for now, not a per-corner one.
    @discardableResult
    public func setBendRadius(entityId: EntityID, _ bendRadius: Float?) -> Bool {
        guard let component = scene.get(component: TubePathComponent.self, for: entityId) else { return false }
        component.bendRadius = bendRadius
        component.contentVersion += 1
        return applyGeometryUpdate(entityId: entityId, component: component)
    }

    /// Changes the radial segment count — a topology change, every ring gets a different vertex
    /// count — and rebuilds the mesh. Always takes the full-rebuild path.
    @discardableResult
    public func setRadialSegments(entityId: EntityID, _ radialSegments: Int) -> Bool {
        guard let component = scene.get(component: TubePathComponent.self, for: entityId) else { return false }
        component.radialSegments = radialSegments
        component.contentVersion += 1
        return applyGeometryUpdate(entityId: entityId, component: component)
    }

    /// Changes the start/end cap flags — a topology change — and rebuilds the mesh.
    @discardableResult
    public func setCaps(entityId: EntityID, capStart: Bool, capEnd: Bool) -> Bool {
        guard let component = scene.get(component: TubePathComponent.self, for: entityId) else { return false }
        component.capStart = capStart
        component.capEnd = capEnd
        component.contentVersion += 1
        return applyGeometryUpdate(entityId: entityId, component: component)
    }

    /// Per-tick safety net: catches `TubePathComponent`s that changed without going through this
    /// extension's editing calls above (their `contentVersion` won't match what was last built)
    /// and updates them. Entities that are already up to date cost one dictionary lookup and one
    /// integer comparison each — no geometry work happens unless something actually changed.
    public func update(deltaTime _: Float, context _: EngineExtensionUpdateContext) {
        for entityId in queryEntities(with: [TubePathComponent.self]) {
            guard let component = scene.get(component: TubePathComponent.self, for: entityId) else { continue }
            guard lastBuiltVersions[entityId] != component.contentVersion else { continue }
            _ = applyGeometryUpdate(entityId: entityId, component: component)
        }
    }

    public func willUnregister() {
        lastBuiltVersions.removeAll()
    }

    // MARK: - Internal

    /// Generates geometry for `component`'s current parameters, then picks a path:
    ///
    /// - **Fast path**: if an existing mesh on `entityId` already has exactly the same vertex
    ///   and index counts the new geometry produces, the topology hasn't changed (same control
    ///   point count, same radial segments, same caps) — only vertex *values* have. Vertex
    ///   attribute data is written directly into the existing mesh's GPU buffers in place, with
    ///   no new buffer allocation and no entity/mesh re-registration. This is the path an
    ///   interactive control-point drag takes on every frame it's called.
    /// - **Full rebuild**: otherwise (including entity creation, where there's no existing mesh
    ///   to compare against).
    @discardableResult
    private func applyGeometryUpdate(entityId: EntityID, component: TubePathComponent) -> Bool {
        guard let geometry = TubeGeometryGenerator.generate(
            controlPoints: component.controlPoints,
            radius: component.radius,
            radialSegments: component.radialSegments,
            capStart: component.capStart,
            capEnd: component.capEnd,
            bendRadius: component.bendRadius
        ) else {
            return false
        }

        if let mesh = fastPathEligibleMesh(entityId: entityId, geometry: geometry) {
            writeGeometryInPlace(geometry, into: mesh)
            touchAfterInPlaceUpdate(entityId: entityId, geometry: geometry)
            lastBuiltVersions[entityId] = component.contentVersion
            return true
        }

        return rebuildMesh(entityId: entityId, component: component, geometry: geometry)
    }

    /// Returns the entity's current mesh if its vertex/index counts exactly match `geometry` —
    /// i.e. it's safe to overwrite in place — or `nil` if there's no existing mesh yet, or its
    /// topology doesn't match (so a full rebuild is required instead).
    private func fastPathEligibleMesh(entityId: EntityID, geometry: TubeGeometryGenerator.Output) -> Mesh? {
        guard let renderComponent = scene.get(component: RenderComponent.self, for: entityId),
              let mesh = renderComponent.mesh.first,
              mesh.metalKitMesh.vertexCount == geometry.positions.count,
              let submesh = mesh.metalKitMesh.submeshes.first,
              submesh.indexCount == geometry.indices.count
        else {
            return nil
        }
        return mesh
    }

    /// Writes new vertex attribute data directly into `mesh`'s existing GPU buffers. The index
    /// buffer is untouched — topology is unchanged by construction (the caller already verified
    /// vertex/index counts match), so the triangle list is still valid as-is.
    private func writeGeometryInPlace(_ geometry: TubeGeometryGenerator.Output, into mesh: Mesh) {
        let vertexBuffers = mesh.metalKitMesh.vertexBuffers
        let vertexCount = geometry.positions.count

        let positionsOut = vertexBuffers[Int(modelPassVerticesIndex.rawValue)].buffer.contents()
            .bindMemory(to: simd_float4.self, capacity: vertexCount)
        let normalsOut = vertexBuffers[Int(modelPassNormalIndex.rawValue)].buffer.contents()
            .bindMemory(to: simd_float4.self, capacity: vertexCount)
        let uvsOut = vertexBuffers[Int(modelPassUVIndex.rawValue)].buffer.contents()
            .bindMemory(to: simd_float2.self, capacity: vertexCount)
        let tangentsOut = vertexBuffers[Int(modelPassTangentIndex.rawValue)].buffer.contents()
            .bindMemory(to: simd_float4.self, capacity: vertexCount)

        for index in 0 ..< vertexCount {
            let position = geometry.positions[index]
            positionsOut[index] = simd_float4(position.x, position.y, position.z, 1.0)

            let normal = geometry.normals[index]
            normalsOut[index] = simd_float4(normal.x, normal.y, normal.z, 0.0)

            uvsOut[index] = geometry.uvs[index]
            tangentsOut[index] = geometry.tangents[index]
        }
    }

    /// After an in-place buffer write, the things a full `setEntityMeshDirect` call would
    /// otherwise have refreshed as a side effect still need doing by hand: the cached bounding
    /// box (used by culling) and the picking/spatial-index acceleration caches (used by
    /// `pickEntity` and frustum culling), both of which are now stale.
    private func touchAfterInPlaceUpdate(entityId: EntityID, geometry: TubeGeometryGenerator.Output) {
        var minBounds = SIMD3<Float>(repeating: Float.infinity)
        var maxBounds = SIMD3<Float>(repeating: -Float.infinity)
        for position in geometry.positions {
            minBounds = simd_min(minBounds, position)
            maxBounds = simd_max(maxBounds, position)
        }

        if let renderComponent = scene.get(component: RenderComponent.self, for: entityId),
           !renderComponent.mesh.isEmpty
        {
            renderComponent.mesh[0].boundingBox = (min: minBounds, max: maxBounds)
        }
        if let transform = scene.get(component: LocalTransformComponent.self, for: entityId) {
            transform.boundingBox = (min: minBounds, max: maxBounds)
        }

        OctreeSystem.shared.markDirty(entityId)
        markEntityPickingDirty(entityId)
    }

    /// Builds a brand-new `Mesh` and (re-)registers it on the entity via `setEntityMeshDirect` —
    /// the only option when there's no existing mesh yet (entity creation) or when vertex/index
    /// counts changed (a topology edit).
    @discardableResult
    private func rebuildMesh(
        entityId: EntityID,
        component: TubePathComponent,
        geometry: TubeGeometryGenerator.Output
    ) -> Bool {
        guard let mesh = Mesh.makeMesh(
            positions: geometry.positions,
            normals: geometry.normals,
            uvs: geometry.uvs,
            tangents: geometry.tangents,
            indices: geometry.indices,
            name: component.assetName
        ) else {
            return false
        }

        setEntityMeshDirect(entityId: entityId, meshes: [mesh], assetName: component.assetName)
        lastBuiltVersions[entityId] = component.contentVersion
        return true
    }
}
