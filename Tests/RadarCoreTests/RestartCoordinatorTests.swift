import Foundation
import Testing
@testable import RadarCore

private func t(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

@Suite struct RestartCoordinatorTests {
    let policy = RestartPolicy()   // stagger 45 s, jitter drawn as 0 in these tests

    @Test func noChangeNoRestart() {
        var s = RestartState(policy: policy, slot: 1, startGeneration: 4)
        #expect(s.evaluate(now: t(0), generation: 4, isLeader: false, peers: [], jitter: { 0 }) == .none)
        #expect(!s.restartRequired)
    }

    @Test func staggerBySlotAndFirstNonLeaderGoesFirst() {
        let peers = [RestartPeer(slot: 1, isLeader: true, appliedGeneration: 1), RestartPeer(slot: 3, isLeader: false, appliedGeneration: 1)]
        var s2 = RestartState(policy: policy, slot: 2, startGeneration: 1)
        #expect(s2.evaluate(now: t(0), generation: 2, isLeader: false, peers: peers, jitter: { 0 }) == .waiting)
        #expect(s2.restartRequired)
        #expect(s2.evaluate(now: t(44), generation: 2, isLeader: false, peers: peers, jitter: { 0 }) == .waiting)
        #expect(s2.evaluate(now: t(45), generation: 2, isLeader: false, peers: peers, jitter: { 0 }) == .exit)
        // Slot 3 waits 90 s and then still needs slot 2 back on the new generation.
        var s3 = RestartState(policy: policy, slot: 3, startGeneration: 1)
        let p3 = [RestartPeer(slot: 1, isLeader: true, appliedGeneration: 1), RestartPeer(slot: 2, isLeader: false, appliedGeneration: 1)]
        #expect(s3.evaluate(now: t(0), generation: 2, isLeader: false, peers: p3, jitter: { 0 }) == .waiting)
        #expect(s3.evaluate(now: t(200), generation: 2, isLeader: false, peers: p3, jitter: { 0 }) == .waiting)
        let back = [RestartPeer(slot: 1, isLeader: true, appliedGeneration: 1), RestartPeer(slot: 2, isLeader: false, appliedGeneration: 2)]
        #expect(s3.evaluate(now: t(201), generation: 2, isLeader: false, peers: back, jitter: { 0 }) == .exit)
    }

    @Test func jitterAddsToStaggerAndIsCapped() {
        var s = RestartState(policy: policy, slot: 1, startGeneration: 1)
        #expect(s.evaluate(now: t(0), generation: 2, isLeader: false, peers: [], jitter: { 99 }) == .waiting)   // capped at 5 s
        #expect(s.exitJitter == 5)
        #expect(s.evaluate(now: t(5), generation: 2, isLeader: false, peers: [], jitter: { 0 }) == .exit)
    }

    @Test func leaderWaitsForOthersWithUpperLimit() {
        var l = RestartState(policy: policy, slot: 1, startGeneration: 1)
        let old = [RestartPeer(slot: 2, isLeader: false, appliedGeneration: 1)]
        #expect(l.evaluate(now: t(0), generation: 2, isLeader: true, peers: old, jitter: { 0 }) == .waiting)
        #expect(l.evaluate(now: t(599), generation: 2, isLeader: true, peers: old, jitter: { 0 }) == .waiting)
        #expect(l.evaluate(now: t(600), generation: 2, isLeader: true, peers: old, jitter: { 0 }) == .exit)
        var l2 = RestartState(policy: policy, slot: 1, startGeneration: 1)
        #expect(l2.evaluate(now: t(0), generation: 2, isLeader: true, peers: [RestartPeer(slot: 2, isLeader: false, appliedGeneration: 2)], jitter: { 0 }) == .exit)
        var single = RestartState(policy: policy, slot: 1, startGeneration: 1)
        #expect(single.evaluate(now: t(0), generation: 2, isLeader: true, peers: [], jitter: { 0 }) == .exit)
    }

    @Test func minimumIntervalGate() {
        #expect(policy.trigger(lastRequestedAt: nil, now: t(0)) == .allowed)
        #expect(policy.trigger(lastRequestedAt: t(0), now: t(100)) == .tooSoon(retryAfterSeconds: 200))
        #expect(policy.trigger(lastRequestedAt: t(0), now: t(300)) == .allowed)
    }

    @Test func policyFromEnvironment() {
        #expect(RestartPolicy.fromEnvironment([:]).staggerSeconds == 45)
        #expect(RestartPolicy.fromEnvironment(["RESTART_STAGGER_SECONDS": ""]).staggerSeconds == 45)
        #expect(RestartPolicy.fromEnvironment(["RESTART_STAGGER_SECONDS": "5"]).staggerSeconds == 15)
        #expect(RestartPolicy.fromEnvironment(["RESTART_STAGGER_SECONDS": "9999"]).staggerSeconds == 300)
        #expect(RestartPolicy.slot(["REPLICA_SLOT": "3"]) == 3)
        #expect(RestartPolicy.slot(["REPLICA_SLOT": ""]) == 1)
    }

    // MARK: simulated cluster

    /// Replicas as real coordinators on a simulated clock; a restart takes `downSeconds`, then a new process starts with the
    /// current generation (as the database repo would hand it out).
    final class Cluster: @unchecked Sendable {
        struct Replica { var slot: Int; var applied: Int; var downUntil: Double?; var coordinator: RestartCoordinator? }
        var clock = 0.0
        var generation = 1
        var replicas: [Int: Replica] = [:]
        let leaderSlot: Int
        let down: Double
        var exits: [(slot: Int, at: Double)] = []
        var maxDown = 0
        var starts: [Int: Int] = [:]
        let policy: RestartPolicy

        init(slots: Int, leaderSlot: Int = 1, down: Double = 20, policy: RestartPolicy = RestartPolicy()) {
            self.leaderSlot = leaderSlot; self.down = down; self.policy = policy
            for slot in 1...slots { start(slot) }
        }

        func start(_ slot: Int) {
            starts[slot, default: 0] += 1
            let c = RestartCoordinator(
                policy: policy, slot: slot, startGeneration: generation, now: { [unowned self] in Date(timeIntervalSince1970: 1_800_000_000 + self.clock) },
                readGeneration: { [unowned self] in self.generation },
                readPeers: { [unowned self] in
                    self.replicas.values.filter { $0.downUntil == nil }.map { RestartPeer(slot: $0.slot, isLeader: $0.slot == self.leaderSlot, appliedGeneration: $0.applied) }
                },
                isLeader: { [unowned self] in slot == self.leaderSlot },
                shutdown: { [unowned self] in self.exits.append((slot, self.clock)); self.replicas[slot]?.downUntil = self.clock + self.down },
                random: { _ in 0 })
            replicas[slot] = Replica(slot: slot, applied: generation, downUntil: nil, coordinator: c)
        }

        func step(_ seconds: Double = 5) async {
            clock += seconds
            for slot in replicas.keys.sorted() {
                guard var r = replicas[slot] else { continue }
                if let until = r.downUntil {
                    if clock >= until { replicas[slot] = nil; start(slot) }
                    continue
                }
                r = replicas[slot]!
                await r.coordinator?.tick()
            }
            maxDown = max(maxDown, replicas.values.filter { $0.downUntil != nil }.count)
        }
    }

    @Test func threeReplicasRestartOneAtATimeLeaderLast() async {
        let cluster = Cluster(slots: 3)
        for _ in 0..<6 { await cluster.step() }
        #expect(cluster.exits.isEmpty)
        cluster.generation = 2
        for _ in 0..<200 { await cluster.step() }
        #expect(cluster.exits.map(\.slot) == [2, 3, 1])           // leader (slot 1) last
        #expect(cluster.maxDown == 1)                              // never two down at once
        #expect(cluster.starts == [1: 2, 2: 2, 3: 2])              // each started exactly twice: no loop
        #expect(cluster.replicas.values.allSatisfy { $0.applied == 2 && $0.downUntil == nil })
        // Further ticks with the unchanged generation cause no more exits.
        let n = cluster.exits.count
        for _ in 0..<200 { await cluster.step() }
        #expect(cluster.exits.count == n)
    }

    @Test func leaderInTheMiddleSlotStillGoesLast() async {
        let cluster = Cluster(slots: 3, leaderSlot: 2)
        cluster.generation = 2
        for _ in 0..<200 { await cluster.step() }
        #expect(cluster.exits.last?.slot == 2)
        #expect(Set(cluster.exits.map(\.slot)) == [1, 2, 3])
        #expect(cluster.maxDown == 1)
    }

    @Test func slowRestartDelaysTheNextReplica() async {
        // Replicas need 120 s to come back (longer than the 45 s stagger): slot 3 must wait for slot 2.
        let cluster = Cluster(slots: 3, down: 120)
        cluster.generation = 2
        for _ in 0..<400 { await cluster.step() }
        #expect(cluster.exits.map(\.slot) == [2, 3, 1])
        #expect(cluster.maxDown == 1)
        let at = cluster.exits.map(\.at)
        #expect(at[1] - at[0] >= 120)
        #expect(at[2] - at[1] >= 120)
    }

    @Test func singleReplicaRestartsOnce() async {
        let cluster = Cluster(slots: 1)
        cluster.generation = 2
        for _ in 0..<100 { await cluster.step() }
        #expect(cluster.exits.count == 1 && cluster.starts[1] == 2)
    }

    @Test func secondRequestWhileRestartingStartsOnlyOneMoreRound() async {
        let cluster = Cluster(slots: 2)
        cluster.generation = 2
        for _ in 0..<10 { await cluster.step() }
        cluster.generation = 3   // second click (the gate would reject it within 5 min; the logic must still be safe)
        for _ in 0..<300 { await cluster.step() }
        #expect(cluster.replicas.values.allSatisfy { $0.applied == 3 && $0.downUntil == nil })
        #expect(cluster.maxDown == 1)
        let before = cluster.exits.count
        for _ in 0..<100 { await cluster.step() }
        #expect(cluster.exits.count == before)
    }

    @Test func databaseErrorKeepsServing() async {
        let flag = Flag()
        let c = RestartCoordinator(slot: 1, startGeneration: 1, readGeneration: { throw ConfigError(description: "db down") },
                                   readPeers: { [] }, isLeader: { false }, shutdown: { flag.set() })
        #expect(await c.tick() == .none)
        #expect(!flag.value)
    }

    final class Flag: @unchecked Sendable { var value = false; func set() { value = true } }
}
