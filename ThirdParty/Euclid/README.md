# Euclid (vendored)

[Euclid](https://github.com/nicklockwood/Euclid) 0.8.18
(`be1096bc1d0810d93d1179ba6a9cf03a7ba564af`), MIT (`LICENSE.md`), with one
patch; tests and examples are left out.

**The patch**, `Sources/Mesh.swift`, `makeWatertight()` → `capPolygons`: the
fallback cap fans triangles from a hole's centroid. On the sliver holes CSG
leaves, the centroid lands on an edge's line and that triangle has no area;
`Polygon(unchecked:)` asserts on it (a Debug crash, an invalid polygon in
Release). It now uses the validating `Polygon(_:material:)`, which skips it.

Upstream still had the unchecked call at 0.10.6. When updating, reapply the
patch unless upstream fixed it; `SubtractCrashTests` fails without it.
