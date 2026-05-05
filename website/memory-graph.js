(function () {
  "use strict";

  const canvas = document.getElementById("memory-signal-graph");
  if (!canvas) return;

  const ctx = canvas.getContext("2d", { alpha: true });
  if (!ctx) return;

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const palette = {
    bg: "#0a0a0a",
    edge: "125, 133, 144",
    node: "230, 230, 230",
    faint: "72, 79, 88",
    teal: "45, 138, 126",
    text: "rgba(125, 133, 144, 0.78)",
  };

  const hardMaxNodes = 230;
  const minLiveNodes = 118;
  const frameInterval = 1000 / 30;
  const tau = Math.PI * 2;

  let width = 960;
  let height = 520;
  let dpr = 1;
  let raf = 0;
  let last = performance.now();
  let lastFrame = -Infinity;
  let elapsed = 0;
  let nextBurst = 0.24;
  let nextPulse = 0.12;
  let nextPrune = 1.4;
  let nextVariant = 1.1;
  let idCounter = 0;
  let seed = 88;
  let running = true;

  let nodes = [];
  let edges = [];
  let pathPulses = [];
  let nodeMap = new Map();
  let edgeMap = new Map();
  let edgeKeys = new Set();
  let projected = new Map();
  let communities = [];

  function random() {
    seed = (seed * 1664525 + 1013904223) >>> 0;
    return seed / 4294967296;
  }

  function clamp(value, min, max) {
    return Math.max(min, Math.min(max, value));
  }

  function lerp(a, b, t) {
    return a + (b - a) * t;
  }

  function smoothstep(t) {
    return t * t * (3 - 2 * t);
  }

  function angularDistance(a, b) {
    return Math.abs(Math.atan2(Math.sin(a - b), Math.cos(a - b)));
  }

  function nodeById(id) {
    return nodeMap.get(id);
  }

  function edgeById(id) {
    return edgeMap.get(id);
  }

  function refreshMaps() {
    nodeMap = new Map(nodes.map((node) => [node.id, node]));
    edgeMap = new Map(edges.map((edge) => [edge.id, edge]));
  }

  function edgeKey(aId, bId) {
    return aId < bId ? aId + ":" + bId : bId + ":" + aId;
  }

  function currentMaxNodes(staticMode) {
    if (staticMode) return 178;
    return Math.min(hardMaxNodes, minLiveNodes + Math.floor(elapsed * 9));
  }

  function createCommunities() {
    communities = [];
    const count = 9;
    for (let i = 0; i < count; i += 1) {
      const theta = (i / count) * tau + (random() - 0.5) * 0.42;
      communities.push({
        id: i,
        theta,
        radial: 0.26 + random() * 0.54,
        z: (random() - 0.5) * 1.34,
        spread: 0.24 + random() * 0.22,
      });
    }
  }

  function pickCommunity(parent) {
    if (parent && parent.type !== "query" && parent.community >= 0 && random() < 0.88) {
      return parent.community;
    }

    if (parent && parent.type !== "query" && parent.community >= 0 && random() < 0.42) {
      const offset = random() < 0.5 ? 1 : -1;
      return (parent.community + communities.length + offset) % communities.length;
    }

    return Math.floor(random() * communities.length);
  }

  function outgoing(nodeId) {
    return edges.filter((edge) => {
      if (edge.a !== nodeId || edge.removing) return false;
      const target = nodeById(edge.b);
      return target && !target.removing;
    });
  }

  function childCount(nodeId) {
    let count = 0;
    for (const edge of edges) {
      if (edge.a === nodeId && !edge.removing) count += 1;
    }
    return count;
  }

  function randomFieldPosition(communityId) {
    const community = communities[communityId];
    if (!community || random() < 0.08) {
      const theta = random() * tau;
      let radial = Math.sqrt(random());
      if (radial < 0.2 && random() < 0.7) radial = 0.2 + random() * 0.28;
      return {
        theta,
        radial: clamp(0.14 + radial * 0.72, 0.14, 0.86),
        z: (random() - 0.5) * 1.45,
      };
    }

    return {
      theta: community.theta + (random() - 0.5) * community.spread * 2.1,
      radial: clamp(community.radial + (random() - 0.5) * 0.22, 0.12, 0.88),
      z: clamp(community.z + (random() - 0.5) * 0.48, -0.92, 0.92),
    };
  }

  function positionNear(parent, affinity, communityId) {
    if (!parent || parent.type === "query" || random() < 0.38) {
      return randomFieldPosition(communityId);
    }

    const spread = 0.52 + (1 - affinity) * 0.96;
    return {
      theta: parent.theta + (random() - 0.5) * spread,
      radial: clamp(parent.radial + (random() - 0.42) * 0.2, 0.14, 0.88),
      z: clamp(parent.z + (random() - 0.5) * 0.48, -0.86, 0.86),
    };
  }

  function makeNode(type, position, affinity, signal, parentId, instant, community) {
    idCounter += 1;
    return {
      id: "n" + idCounter,
      type,
      theta: position.theta,
      radial: position.radial,
      z: position.z,
      affinity,
      community,
      signal,
      parentId,
      age: 0,
      hit: 0,
      spawn: instant ? 1 : 0,
      removing: false,
      remove: 0,
      phase: random() * tau,
      phase2: random() * tau,
      drift: 0.008 + random() * 0.018,
      spin: (random() - 0.5) * 0.01,
      flow: 0.55 + random() * 0.9,
    };
  }

  function addNode(node) {
    nodes.push(node);
    nodeMap.set(node.id, node);
    return node;
  }

  function makeEdge(a, b, signal, kind) {
    if (!a || !b || a.id === b.id) return null;
    const key = edgeKey(a.id, b.id);
    if (edgeKeys.has(key)) return null;

    const edge = {
      id: "e" + a.id + "-" + b.id + "-" + Math.floor(random() * 1000000),
      key,
      a: a.id,
      b: b.id,
      signal,
      kind,
      age: 0,
      removing: false,
      remove: 0,
    };
    edges.push(edge);
    edgeMap.set(edge.id, edge);
    edgeKeys.add(key);
    return edge;
  }

  function nearestNodes(target, limit) {
    return nodes
      .filter((node) => node.type !== "query" && node.id !== target.id && !node.removing)
      .map((node) => ({
        node,
        score:
          angularDistance(node.theta, target.theta) * 1.25 +
          Math.abs(node.radial - target.radial) * 1.4 +
          Math.abs(node.z - target.z) * 0.42 +
          (node.community === target.community ? -0.34 : 0.56) +
          random() * 0.28,
      }))
      .sort((a, b) => a.score - b.score)
      .slice(0, limit)
      .map((item) => item.node);
  }

  function connectedEdges(nodeId) {
    return edges.filter((edge) => {
      if (edge.removing || (edge.a !== nodeId && edge.b !== nodeId)) return false;
      const a = nodeById(edge.a);
      const b = nodeById(edge.b);
      return a && b && !a.removing && !b.removing;
    });
  }

  function localExploreEdges(root, excludedEdgeIds, limit) {
    if (!root || root.type === "query") return [];

    const seenNodes = new Set([root.id]);
    const frontier = [root.id];
    const candidates = [];

    for (let depth = 0; depth < 2; depth += 1) {
      const next = [];
      for (const nodeId of frontier) {
        for (const edge of connectedEdges(nodeId)) {
          if (excludedEdgeIds.has(edge.id)) continue;
          const a = nodeById(edge.a);
          const b = nodeById(edge.b);
          if (!a || !b) continue;
          if (a.community !== root.community || b.community !== root.community) continue;

          const other = edge.a === nodeId ? b : a;
          candidates.push({
            edge,
            score:
              edge.signal * 1.2 +
              other.signal * 0.72 +
              (edge.kind === "local" ? 0.42 : 0) +
              (depth === 0 ? 0.24 : 0) +
              random() * 0.18,
          });

          if (!seenNodes.has(other.id)) {
            seenNodes.add(other.id);
            next.push(other.id);
          }
        }
      }
      frontier.splice(0, frontier.length, ...next.slice(0, 10));
    }

    const selected = [];
    const selectedIds = new Set();
    candidates
      .sort((a, b) => b.score - a.score)
      .forEach(({ edge }) => {
        if (selected.length >= limit || selectedIds.has(edge.id)) return;
        selected.push(edge.id);
        selectedIds.add(edge.id);
      });

    return selected;
  }

  function chooseParent(biasToStrong) {
    const query = nodes[0];
    const candidates = nodes
      .filter((node) => node.type !== "query" && !node.removing)
      .sort((a, b) => {
        const bScore = b.signal * 1.35 + b.affinity * 0.72 + b.hit * 0.24;
        const aScore = a.signal * 1.35 + a.affinity * 0.72 + a.hit * 0.24;
        return bScore - aScore;
      });

    if (!candidates.length) return query;
    if (random() > biasToStrong && random() < 0.68) return query;
    if (random() < 0.18) return candidates[Math.floor(random() * candidates.length)];
    return candidates[Math.floor(random() * Math.min(14, candidates.length))];
  }

  function addMemory(biasToStrong, instant, force) {
    if (!force && nodes.length >= currentMaxNodes(false)) return null;
    if (nodes.length >= hardMaxNodes) return null;

    const parent = chooseParent(biasToStrong);
    const community = pickCommunity(parent);
    const affinity = clamp(
      (parent.type === "query" ? 0.18 + random() * 0.36 : parent.affinity * 0.62 + random() * 0.42),
      0.05,
      0.98
    );
    const pos = positionNear(parent, affinity, community);
    const roll = random();
    const type = roll > 0.72 ? "procedure" : roll > 0.42 ? "fact" : "evidence";
    const node = addNode(makeNode(type, pos, affinity, instant ? 0.11 : 0.03, parent.id, instant, community));
    makeEdge(
      parent,
      node,
      instant ? 0.12 : 0.055,
      parent.type === "query" || parent.community === community ? "derived" : "bridge"
    );

    if (nodes.length > 12 && random() < 0.9) {
      const near = nearestNodes(node, 8);
      const linkCount = random() < 0.35 ? 4 : random() < 0.76 ? 3 : 2;
      for (let i = 0; i < Math.min(linkCount, near.length); i += 1) {
        const other = near[i];
        if (other.id === parent.id) continue;
        const kind = other.community === node.community ? "local" : "association";
        if (random() < 0.55) makeEdge(other, node, 0.05 + random() * 0.07, kind);
        else makeEdge(node, other, 0.05 + random() * 0.07, kind);
      }
    }

    return node;
  }

  function addBurst() {
    const deficit = currentMaxNodes(false) - nodes.length;
    if (deficit <= 0) return;

    const count = Math.min(deficit, 5 + Math.floor(random() * 8));
    for (let i = 0; i < count; i += 1) {
      addMemory(0.48 + random() * 0.34, false, false);
    }
  }

  function addVariant() {
    const strong = nodes
      .filter((node) => node.type !== "query" && !node.removing && node.signal > 0.22)
      .sort((a, b) => b.signal + b.affinity - (a.signal + a.affinity));
    if (!strong.length || nodes.length >= hardMaxNodes) return;

    const parent = strong[Math.floor(random() * Math.min(12, strong.length))];
    const pos = {
      theta: parent.theta + (random() - 0.5) * (0.24 + random() * 0.32),
      radial: clamp(parent.radial + (random() - 0.46) * 0.1, 0.14, 0.88),
      z: clamp(parent.z + (random() - 0.5) * 0.2, -0.86, 0.86),
    };
    const node = addNode(
      makeNode(
        "variant",
        pos,
        clamp(parent.affinity + random() * 0.18 - 0.04, 0.08, 0.99),
        0.09,
        parent.id,
        false,
        parent.community
      )
    );
    makeEdge(parent, node, 0.16, "derived");

    const near = nearestNodes(node, 5);
    for (let i = 0; i < Math.min(3, near.length); i += 1) {
      const other = near[i];
      if (other.community !== node.community || other.id === parent.id) continue;
      if (random() < 0.5) makeEdge(other, node, 0.08 + random() * 0.08, "local");
      else makeEdge(node, other, 0.08 + random() * 0.08, "local");
    }

    const parentEdge = edges.find((edge) => edge.b === parent.id && !edge.removing);
    if (parentEdge && random() < 0.72) parentEdge.signal *= 0.68;
  }

  function markNodeForRemoval(node) {
    if (!node || node.type === "query" || node.removing) return;
    node.removing = true;
    for (const edge of edges) {
      if (edge.a === node.id || edge.b === node.id) edge.removing = true;
    }
  }

  function pruneWeakMemories(force) {
    const targetMax = currentMaxNodes(false);
    if (!force && nodes.length <= Math.max(minLiveNodes, targetMax - 8)) return;

    const candidates = nodes
      .filter((node) => node.type !== "query" && !node.removing && (force || node.age > 2.4))
      .map((node) => ({
        node,
        score:
          node.signal * 1.55 +
          node.affinity * 0.22 +
          node.hit * 0.32 +
          childCount(node.id) * 0.06 +
          random() * 0.08,
      }))
      .sort((a, b) => a.score - b.score);

    const pressure = Math.max(1, nodes.length - targetMax + 2);
    const removals = Math.min(force ? 5 : 3, pressure, candidates.length);
    for (let i = 0; i < removals; i += 1) {
      const candidate = candidates[i];
      if (!candidate) continue;
      if (!force && candidate.score > 0.48) continue;
      markNodeForRemoval(candidate.node);
    }
  }

  function selectPath() {
    const path = [];
    const segmentStrengths = [];
    let current = nodes[0];
    let strength = 0.86 + random() * 0.14;
    const visited = new Set([current.id]);
    const minDepth = 5 + Math.floor(random() * 3);
    const maxDepth = 10 + Math.floor(random() * 3);

    for (let depth = 0; depth < maxDepth; depth += 1) {
      const options = outgoing(current.id)
        .map((edge) => {
          const node = nodeById(edge.b);
          if (!node || visited.has(node.id)) return null;
          const localPenalty = depth < minDepth && edge.kind === "local" ? -0.56 : 0;
          const kindBias =
            edge.kind === "derived" ? 0.32 :
              edge.kind === "bridge" ? 0.18 :
                edge.kind === "local" ? 0.08 : 0;
          return {
            edge,
            node,
            score:
              edge.signal * 1.18 +
              node.signal * 1.05 +
              node.affinity * 0.7 +
              kindBias +
              localPenalty +
              random() * 0.34,
          };
        })
        .filter(Boolean)
        .sort((a, b) => b.score - a.score);

      if (!options.length) break;

      const choicePool = options.slice(0, depth === 0 ? 9 : 5);
      const choice = choicePool[Math.floor(random() * choicePool.length)];
      path.push(choice.edge.id);
      segmentStrengths.push(strength);
      current = choice.node;
      visited.add(current.id);

      strength = clamp(strength * (0.5 + current.affinity * 0.42 + choice.edge.signal * 0.16), 0.04, 1);
      if (depth + 1 >= minDepth && (strength < 0.13 || random() < 0.05 + depth * 0.035)) break;
    }

    if (!path.length) return null;
    const pathSet = new Set(path);
    const localEdgeIds = localExploreEdges(current, pathSet, 5 + Math.floor(random() * 5));
    return {
      edgeIds: path,
      localEdgeIds,
      segmentStrengths,
      index: 0,
      progress: 0,
      rootStrength: segmentStrengths[0],
      speed: 1.28 + random() * 0.8,
      done: false,
      settle: 0,
    };
  }

  function emitPulse() {
    const pulse = selectPath();
    if (pulse) pathPulses.push(pulse);
    if (nodes[0]) nodes[0].hit = 1;
  }

  function completePulse(pulse) {
    const pathSet = new Set(pulse.edgeIds);
    let delivered = pulse.rootStrength;

    for (const edgeId of pulse.edgeIds) {
      const edge = edgeById(edgeId);
      if (!edge) continue;

      const target = nodeById(edge.b);
      if (!target || target.removing) continue;

      target.signal = clamp(target.signal + delivered * 0.34, 0, 1);
      target.hit = clamp(target.hit + delivered * 0.9, 0, 1);
      edge.signal = clamp(edge.signal + delivered * 0.42, 0, 1);

      for (const sibling of outgoing(edge.a)) {
        if (!pathSet.has(sibling.id)) sibling.signal *= 0.78 - delivered * 0.1;
      }

      delivered = clamp(delivered * (0.56 + target.affinity * 0.34 + edge.signal * 0.12), 0, 1);
    }

    for (const edgeId of pulse.localEdgeIds || []) {
      const edge = edgeById(edgeId);
      if (!edge) continue;
      const a = nodeById(edge.a);
      const b = nodeById(edge.b);
      if (!a || !b || a.removing || b.removing) continue;

      edge.signal = clamp(edge.signal + pulse.rootStrength * 0.18, 0, 1);
      a.signal = clamp(a.signal + pulse.rootStrength * 0.12, 0, 1);
      b.signal = clamp(b.signal + pulse.rootStrength * 0.16, 0, 1);
      a.hit = clamp(a.hit + pulse.rootStrength * 0.42, 0, 1);
      b.hit = clamp(b.hit + pulse.rootStrength * 0.5, 0, 1);
    }
  }

  function resetGraph(staticMode) {
    seed = 88;
    idCounter = 0;
    elapsed = 0;
    nextBurst = staticMode ? 999 : 0.2;
    nextPulse = staticMode ? 999 : 0.08;
    nextPrune = staticMode ? 999 : 1.2;
    nextVariant = staticMode ? 999 : 1.1;
    nodes = [];
    edges = [];
    pathPulses = [];
    nodeMap = new Map();
    edgeMap = new Map();
    edgeKeys = new Set();
    createCommunities();

    const query = addNode(
      makeNode(
        "query",
        { theta: 0, radial: 0.02, z: 0 },
        1,
        1,
        null,
        true,
        -1
      )
    );
    query.phase = 0;
    query.drift = 0;
    query.spin = 0;

    const starterCount = staticMode ? 172 : 132;
    for (let i = 0; i < starterCount; i += 1) {
      addMemory(0.42 + random() * 0.34, true, true);
    }

    const primePasses = staticMode ? 22 : 14;
    for (let i = 0; i < primePasses; i += 1) {
      const pulse = selectPath();
      if (pulse) completePulse(pulse);
    }

    if (staticMode) {
      for (const node of nodes) {
        node.spawn = 1;
        node.hit = 0;
      }
      for (const edge of edges) edge.remove = 0;
    }
  }

  function update(dt) {
    elapsed += dt;
    nextBurst -= dt;
    nextPulse -= dt;
    nextPrune -= dt;
    nextVariant -= dt;

    if (nextBurst <= 0) {
      addBurst();
      nextBurst = nodes.length < 174 ? 0.18 + random() * 0.3 : 0.36 + random() * 0.52;
    }

    if (nextVariant <= 0) {
      const count = random() < 0.18 ? 3 : random() < 0.48 ? 2 : 1;
      for (let i = 0; i < count; i += 1) addVariant();
      nextVariant = 0.62 + random() * 1.08;
    }

    if (nextPrune <= 0) {
      pruneWeakMemories(nodes.length > currentMaxNodes(false) + 12);
      nextPrune = 0.58 + random() * 0.86;
    }

    if (nextPulse <= 0) {
      const pulseCount = nodes.length > 178 ? 4 : nodes.length > 132 ? 3 : 2;
      for (let i = 0; i < pulseCount; i += 1) emitPulse();
      nextPulse = 0.26 + random() * 0.2;
    }

    for (const node of nodes) {
      node.age += dt;
      node.spawn = clamp(node.spawn + dt * 3.4, 0, 1);
      node.hit = Math.max(0, node.hit - dt * 1.7);
      node.signal *= Math.pow(0.985, dt * 6);
      if (node.type !== "query") node.theta += node.spin * dt;
      if (node.type !== "query" && !node.removing) {
        node.radial = clamp(
          node.radial + Math.sin(elapsed * 0.18 * node.flow + node.phase2) * 0.0016 * dt,
          0.12,
          0.9
        );
        node.z = clamp(
          node.z + Math.cos(elapsed * 0.14 * node.flow + node.phase) * 0.006 * dt,
          -0.92,
          0.92
        );
      }
      if (node.removing) node.remove = clamp(node.remove + dt * 2.6, 0, 1);
    }

    for (const edge of edges) {
      edge.age += dt;
      edge.signal *= Math.pow(0.987, dt * 6);
      if (edge.removing) edge.remove = clamp(edge.remove + dt * 2.8, 0, 1);
    }

    for (let i = pathPulses.length - 1; i >= 0; i -= 1) {
      const pulse = pathPulses[i];
      if (pulse.done) {
        pulse.settle += dt * 1.65;
        if (pulse.settle >= 1) pathPulses.splice(i, 1);
        continue;
      }

      pulse.progress += dt * pulse.speed;
      while (pulse.progress >= 1 && !pulse.done) {
        pulse.progress -= 1;
        pulse.index += 1;
        if (pulse.index >= pulse.edgeIds.length) {
          pulse.done = true;
          pulse.progress = 1;
          completePulse(pulse);
        }
      }
    }

    const beforeNodes = nodes.length;
    nodes = nodes.filter((node) => node.remove < 1);
    const nodeIds = new Set(nodes.map((node) => node.id));
    edges = edges.filter((edge) => edge.remove < 1 && nodeIds.has(edge.a) && nodeIds.has(edge.b));
    if (nodes.length !== beforeNodes || edges.length !== edgeMap.size) refreshMaps();

    if (elapsed > 64 && nodes.length < minLiveNodes * 0.55) resetGraph(false);
  }

  function organicPoint(node, time) {
    if (node.type === "query") {
      return { x: 0, y: 0, z: 0 };
    }

    const theta =
      node.theta +
      (reduceMotion.matches
        ? 0
        : Math.sin(time * 0.16 * node.flow + node.phase) * 0.052 +
          Math.sin(time * 0.047 + node.phase2) * 0.045);
    const radial =
      node.radial +
      (reduceMotion.matches
        ? 0
        : Math.sin(time * 0.12 * node.flow + node.phase * 1.7) * node.drift * 1.9 +
          Math.cos(time * 0.033 + node.phase2) * node.drift * 1.4);
    const z =
      node.z +
      (reduceMotion.matches
        ? 0
        : Math.cos(time * 0.09 * node.flow + node.phase) * 0.16 +
          Math.sin(time * 0.041 + node.phase2) * 0.09);
    const contour =
      1 +
      Math.sin(theta * 3.1 + time * 0.022) * 0.06 +
      Math.cos(theta * 5.2 - time * 0.017) * 0.04;

    return {
      x: Math.cos(theta) * radial * contour,
      y: Math.sin(theta) * radial * (0.73 + z * 0.035) + Math.sin(theta * 2) * 0.038 * radial,
      z,
    };
  }

  function projectPoint(node, time) {
    const point = organicPoint(node, time);
    const yaw = reduceMotion.matches ? -0.34 : time * 0.054 + Math.sin(time * 0.055) * 0.18;
    const pitch = reduceMotion.matches ? 0.22 : 0.26 + Math.sin(time * 0.042) * 0.16;
    const roll = reduceMotion.matches ? 0 : Math.sin(time * 0.031) * 0.075;
    const driftX = reduceMotion.matches ? 0 : Math.sin(time * 0.21) * 9;
    const driftY = reduceMotion.matches ? 0 : Math.cos(time * 0.17) * 6;

    const cy = Math.cos(yaw);
    const sy = Math.sin(yaw);
    const cp = Math.cos(pitch);
    const sp = Math.sin(pitch);
    const cr = Math.cos(roll);
    const sr = Math.sin(roll);

    const x1 = point.x * cy + point.z * 0.82 * sy;
    const z1 = -point.x * sy + point.z * 0.82 * cy;
    const y2 = point.y * cp - z1 * sp;
    const z2 = point.y * sp + z1 * cp;
    const x3 = x1 * cr - y2 * sr;
    const y3 = x1 * sr + y2 * cr;
    const perspective = clamp(1 + z2 * 0.13, 0.82, 1.18);

    return {
      x: width / 2 + x3 * width * 0.38 * perspective + driftX,
      y: height / 2 + y3 * height * 0.49 * perspective + driftY,
      z: z2,
      depth: clamp((z2 + 1.45) / 2.9, 0, 1),
    };
  }

  function edgePoints(edge) {
    const a = projected.get(edge.a);
    const b = projected.get(edge.b);
    if (!a || !b) return null;
    return { a, b };
  }

  function edgeDepth(edge) {
    const points = edgePoints(edge);
    if (!points) return 0;
    return (points.a.depth + points.b.depth) * 0.5;
  }

  function edgeStrength(edge) {
    const source = nodeById(edge.a);
    const target = nodeById(edge.b);
    if (!source || !target) return 0;
    return clamp(edge.signal * 0.82 + target.signal * 0.5 + source.hit * 0.12 + target.hit * 0.22, 0, 1);
  }

  function drawBackdrop() {
    ctx.fillStyle = palette.bg;
    ctx.fillRect(0, 0, width, height);
  }

  function drawEdge(edge) {
    const points = edgePoints(edge);
    if (!points) return;

    const target = nodeById(edge.b);
    const visible = (target ? target.spawn : 1) * (1 - edge.remove);
    if (visible <= 0) return;

    const depth = edgeDepth(edge);
    const base = edge.kind === "association" ? 0.075 : 0.115;
    const alpha = clamp(base + edge.signal * 0.36, 0.055, 0.68) * visible * (0.56 + depth * 0.76);
    ctx.strokeStyle = `rgba(${palette.edge}, ${alpha})`;
    ctx.lineWidth = edge.kind === "association" ? 0.55 + edge.signal * 0.62 : 0.68 + edge.signal * 1.02;
    ctx.beginPath();
    ctx.moveTo(points.a.x, points.a.y);
    ctx.lineTo(points.b.x, points.b.y);
    ctx.stroke();
  }

  function drawMemoryEdge(edge) {
    const strength = edgeStrength(edge);
    if (strength < 0.2) return;

    const points = edgePoints(edge);
    if (!points) return;

    const target = nodeById(edge.b);
    const visible = (target ? target.spawn : 1) * (1 - edge.remove);
    if (visible <= 0) return;

    const depth = edgeDepth(edge);
    const alpha = clamp((strength - 0.12) * 0.72, 0, 0.68) * visible * (0.68 + depth * 0.58);
    ctx.strokeStyle = strength > 0.46
      ? `rgba(${palette.teal}, ${alpha})`
      : `rgba(${palette.node}, ${alpha * 0.66})`;
    ctx.lineWidth = 0.48 + strength * 1.08 + depth * 0.22;
    ctx.beginPath();
    ctx.moveTo(points.a.x, points.a.y);
    ctx.lineTo(points.b.x, points.b.y);
    ctx.stroke();
  }

  function drawPulsePath(pulse) {
    const fade = pulse.done ? 1 - smoothstep(clamp(pulse.settle, 0, 1)) : 1;
    if (fade <= 0) return;

    for (let i = 0; i < pulse.edgeIds.length; i += 1) {
      const edge = edgeById(pulse.edgeIds[i]);
      if (!edge) continue;

      const points = edgePoints(edge);
      if (!points) continue;

      const segmentActive = i < pulse.index || pulse.done;
      const segmentCurrent = i === pulse.index && !pulse.done;
      if (!segmentActive && !segmentCurrent) continue;

      const t = segmentCurrent ? clamp(pulse.progress, 0, 1) : 1;
      const strength = pulse.segmentStrengths[i] || pulse.rootStrength;
      const end = {
        x: lerp(points.a.x, points.b.x, t),
        y: lerp(points.a.y, points.b.y, t),
      };

      ctx.strokeStyle = `rgba(${palette.teal}, ${clamp((0.18 + strength * 0.72) * fade, 0, 0.94)})`;
      ctx.lineWidth = 0.36 + strength * 0.82;
      ctx.beginPath();
      ctx.moveTo(points.a.x, points.a.y);
      ctx.lineTo(end.x, end.y);
      ctx.stroke();

      if (segmentCurrent) {
        ctx.fillStyle = `rgba(${palette.teal}, ${clamp((0.44 + strength * 0.42) * fade, 0, 0.98)})`;
        ctx.beginPath();
        ctx.arc(end.x, end.y, 1.05, 0, tau);
        ctx.fill();
      }
    }

    if (!pulse.done || !pulse.localEdgeIds || !pulse.localEdgeIds.length) return;

    for (let i = 0; i < pulse.localEdgeIds.length; i += 1) {
      const edge = edgeById(pulse.localEdgeIds[i]);
      if (!edge) continue;

      const points = edgePoints(edge);
      if (!points) continue;

      const reveal = smoothstep(clamp(pulse.settle * 2.4 - i * 0.12, 0, 1));
      const localFade = reveal * (1 - smoothstep(clamp(pulse.settle, 0, 1)));
      if (localFade <= 0) continue;

      const strength = pulse.rootStrength * Math.pow(0.88, i);
      ctx.strokeStyle = `rgba(${palette.teal}, ${clamp((0.14 + strength * 0.5) * localFade, 0, 0.58)})`;
      ctx.lineWidth = 0.28 + strength * 0.62;
      ctx.beginPath();
      ctx.moveTo(points.a.x, points.a.y);
      ctx.lineTo(points.b.x, points.b.y);
      ctx.stroke();
    }
  }

  function drawNode(node) {
    const p = projected.get(node.id);
    if (!p) return;

    const visible = node.spawn * (1 - node.remove);
    if (visible <= 0) return;

    const active = clamp(node.signal * 0.74 + node.hit * 0.38, 0, 1);
    const depth = p.depth;
    const radius = 1.75;

    ctx.fillStyle =
      node.type === "query"
        ? `rgba(${palette.teal}, ${0.94 * visible})`
        : active > 0.3
          ? `rgba(${palette.teal}, ${clamp(0.3 + active * 0.58, 0.22, 0.92) * visible * (0.72 + depth * 0.36)})`
          : `rgba(${palette.node}, ${clamp(0.18 + active * 0.62, 0.1, 0.8) * visible * (0.44 + depth * 0.7)})`;
    ctx.beginPath();
    ctx.arc(p.x, p.y, radius, 0, tau);
    ctx.fill();
  }

  function draw() {
    const time = elapsed;
    projected = new Map();
    for (const node of nodes) {
      projected.set(node.id, projectPoint(node, time));
    }

    drawBackdrop();
    ctx.lineCap = "round";
    const orderedEdges = edges.slice().sort((a, b) => edgeDepth(a) - edgeDepth(b));
    for (const edge of orderedEdges) drawEdge(edge);
    for (const edge of orderedEdges) drawMemoryEdge(edge);
    for (const pulse of pathPulses) drawPulsePath(pulse);
    const orderedNodes = nodes.slice().sort((a, b) => {
      const aPoint = projected.get(a.id);
      const bPoint = projected.get(b.id);
      return (aPoint ? aPoint.depth : 0) - (bPoint ? bPoint.depth : 0);
    });
    for (const node of orderedNodes) drawNode(node);
  }

  function frame(now) {
    raf = 0;
    if (!running || reduceMotion.matches) return;

    if (now - lastFrame < frameInterval) {
      raf = requestAnimationFrame(frame);
      return;
    }

    const dt = Math.min(0.06, (now - last) / 1000);
    last = now;
    lastFrame = now;
    update(dt);
    draw();
    raf = requestAnimationFrame(frame);
  }

  function resize() {
    const rect = canvas.getBoundingClientRect();
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    width = Math.max(320, Math.floor(rect.width));
    height = Math.max(320, Math.floor(rect.height));
    canvas.width = Math.floor(width * dpr);
    canvas.height = Math.floor(height * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    draw();
  }

  function stopFrame() {
    cancelAnimationFrame(raf);
    raf = 0;
  }

  function startFrame() {
    if (raf || reduceMotion.matches || !running) return;
    last = performance.now();
    lastFrame = -Infinity;
    raf = requestAnimationFrame(frame);
  }

  function start() {
    stopFrame();
    resetGraph(reduceMotion.matches);
    resize();
    startFrame();
  }

  if ("ResizeObserver" in window) {
    const observer = new ResizeObserver(resize);
    observer.observe(canvas);
  } else {
    window.addEventListener("resize", resize);
  }

  if ("IntersectionObserver" in window) {
    const visibleObserver = new IntersectionObserver(
      (entries) => {
        running = entries.some((entry) => entry.isIntersecting);
        if (running) startFrame();
        else stopFrame();
      },
      { threshold: 0.04 }
    );
    visibleObserver.observe(canvas);
  }

  if ("addEventListener" in reduceMotion) {
    reduceMotion.addEventListener("change", start);
  } else if ("addListener" in reduceMotion) {
    reduceMotion.addListener(start);
  }

  document.addEventListener("visibilitychange", () => {
    if (document.hidden) {
      stopFrame();
    } else {
      startFrame();
    }
  });

  start();
})();
