import std/sets
import adapter

proc traverse*(graph: WorkingGraph; rootOid: string; depth = 1): seq[string] =
  if depth < 0 or depth > 10: raise newException(ValueError, "Traversal depth must be 0..10")
  discard graph.neighbors(rootOid) # validates the root even for depth zero
  result = @[rootOid]
  var seen = [rootOid].toHashSet
  var frontier = @[rootOid]
  for level in 0..<depth:
    var next: seq[string]
    for oid in frontier:
      for other in graph.neighbors(oid):
        if other notin seen:
          seen.incl(other)
          result.add(other)
          next.add(other)
    frontier = next
    if frontier.len == 0: break
