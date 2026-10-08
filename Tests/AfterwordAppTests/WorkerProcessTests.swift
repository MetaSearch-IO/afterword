import Foundation
import Darwin
import XCTest
@testable import AfterwordApp

final class WorkerProcessTests: XCTestCase, @unchecked Sendable {
    private final class Group: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int32?
        func set(_ value: Int32) { lock.withLock { self.value = value } }
        func take() -> Int32? { lock.withLock { let result = value; value = nil; return result } }
    }
    private func fixture(_ script: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afterword-worker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("fixture.py")
        try Data(script.utf8).write(to: file)
        return (directory, file)
    }

    func testDrainsLargeStderrAndRequiresTerminalEvent() async throws {
        let (directory, script) = try fixture("""
        import json, sys
        sys.stderr.write('x' * 600000)
        print(json.dumps({'protocol_version': 1, 'run_id': 'test', 'type': 'started'}), flush=True)
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await WorkerProcess(runID: "test").run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                         arguments: [script.path], directory: directory) { _ in }
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertNil(result.terminal)
        XCTAssertTrue(result.cleanupConfirmed)
    }

    func testBackgroundPolicyIsInheritedByWorkerDescendantsAndNativeThreads() async throws {
        let (directory, script) = try fixture("""
        import ctypes, json, pathlib, subprocess, sys, threading
        lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
        lib.mach_thread_self.restype = ctypes.c_uint
        lib.qos_class_self.restype = ctypes.c_uint
        class ThreadInfo(ctypes.Structure):
            _fields_ = [('user_time', ctypes.c_uint64), ('system_time', ctypes.c_uint64),
                ('cpu_usage', ctypes.c_int), ('policy', ctypes.c_int), ('run_state', ctypes.c_int),
                ('flags', ctypes.c_int), ('sleep_time', ctypes.c_int), ('current_priority', ctypes.c_int),
                ('priority', ctypes.c_int), ('max_priority', ctypes.c_int), ('name', ctypes.c_char * 64)]
        def sample():
            info = ThreadInfo()
            count = ctypes.c_uint(ctypes.sizeof(info) // ctypes.sizeof(ctypes.c_int))
            thread = lib.mach_thread_self()
            try:
                assert lib.thread_info(thread, 5, ctypes.byref(info), ctypes.byref(count)) == 0
                return dict(qos=lib.qos_class_self(), priority=info.priority, max_priority=info.max_priority)
            finally:
                task = ctypes.c_uint.in_dll(lib, 'mach_task_self_').value
                lib.mach_port_deallocate(task, thread)
        depth = int(sys.argv[1]) if len(sys.argv) > 1 else 0
        samples = [sample()]
        if depth < 2:
            child = subprocess.run([sys.executable, __file__, str(depth + 1)],
                start_new_session=depth == 0, capture_output=True, text=True, check=True)
            samples.extend(json.loads(child.stdout))
        else:
            def elevated_thread():
                assert lib.pthread_set_qos_class_self_np(25, 0) == 0
                samples.append(sample())
            thread = threading.Thread(target=elevated_thread)
            thread.start()
            thread.join()
        if depth:
            print(json.dumps(samples), flush=True)
        else:
            pathlib.Path('policy.json').write_text(json.dumps(samples))
            print(json.dumps(dict(protocol_version=1, run_id='test', type='completed')), flush=True)
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await WorkerProcess(runID: "test").run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                         arguments: [script.path], directory: directory) { _ in }
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(result.terminal?.type, "completed")
        XCTAssertTrue(result.cleanupConfirmed)
        let data = try Data(contentsOf: directory.appendingPathComponent("policy.json"))
        let samples = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Int]])
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples.prefix(3).compactMap { $0["qos"] }, [9, 9, 9])
        XCTAssertEqual(samples.last?["qos"], 25)
        for sample in samples {
            XCTAssertEqual(sample["priority"], 4)
            XCTAssertEqual(sample["max_priority"], 4)
        }
    }

    func testOversizedAndWrongRunEventsAreRejected() async throws {
        for output in ["print('x' * 70000, flush=True)", "print('{\"protocol_version\":1,\"run_id\":\"other\",\"type\":\"completed\"}', flush=True)"] {
            let (directory, script) = try fixture(output)
            defer { try? FileManager.default.removeItem(at: directory) }
            let result = try await WorkerProcess(runID: "test").run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                             arguments: [script.path], directory: directory) { _ in }
            XCTAssertNotNil(result.error)
            XCTAssertTrue(result.cleanupConfirmed)
        }
    }

    func testCancellationWaitsForOwnedProcessGroupExit() async throws {
        let (directory, script) = try fixture("""
        import json, os, signal, subprocess, sys
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'], start_new_session=True)
        print(json.dumps({'protocol_version':1, 'run_id':'test', 'type':'stage_started', 'stage':'asr', 'process_group_id':child.pid}), flush=True)
        sys.stdin.readline()
        os.killpg(child.pid, signal.SIGKILL)
        child.wait()
        print(json.dumps({'protocol_version':1, 'run_id':'test', 'type':'cancelled', 'stage':'asr'}), flush=True)
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = WorkerProcess(runID: "test")
        let started = expectation(description: "Native child started")
        let operation = Task {
            try await process.run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path], directory: directory) { event in
                if event.process_group_id != nil { started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 5)
        let before = Date()
        process.cancel()
        let result = try await operation.value
        XCTAssertLessThan(Date().timeIntervalSince(before), 10)
        XCTAssertTrue(result.cleanupConfirmed)
        XCTAssertEqual(result.terminal?.type, "cancelled")
    }

    func testHungWorkerIsKilledAfterCancellationGracePeriod() async throws {
        let (directory, script) = try fixture("""
        import json, signal, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        print(json.dumps({'protocol_version':1,'run_id':'test','type':'started'}),flush=True)
        time.sleep(60)
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = WorkerProcess(runID: "test")
        let started = expectation(description: "Hung worker started")
        let operation = Task {
            try await process.run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path], directory: directory) { event in
                if event.type == "started" { started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 5)
        let before = Date()
        process.cancel()
        let result = try await operation.value
        XCTAssertLessThan(Date().timeIntervalSince(before), 10)
        XCTAssertNotEqual(result.exitStatus, 0)
        XCTAssertTrue(result.cleanupConfirmed)
    }

    func testPrematureCleanupEventDoesNotReleaseLiveChildGroup() async throws {
        let (directory, script) = try fixture("""
        import json, subprocess, sys
        child = subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'],start_new_session=True,
            stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        def event(kind, **extra):
            print(json.dumps(dict(protocol_version=1,run_id='test',type=kind,stage='asr',process_group_id=child.pid,**extra)),flush=True)
        event('stage_started')
        event('stage_completed',process_group_finished=True)
        """)
        let group = Group()
        defer {
            if let pid = group.take() { kill(-pid, SIGKILL) }
            try? FileManager.default.removeItem(at: directory)
        }
        let process = WorkerProcess(runID: "test")
        let result = try await process.run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path], directory: directory) { event in
            if let pid = event.process_group_id { group.set(pid) }
        }
        XCTAssertFalse(result.cleanupConfirmed)
        if let pid = group.take() { kill(-pid, SIGKILL) }
        let deadline = Date().addingTimeInterval(2)
        while !process.cleanupConfirmed() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(process.cleanupConfirmed())
    }

    func testProgressKeepsCountsAcrossNativeLifecycleAndPhaseChanges() async throws {
        let (directory, script) = try fixture("""
        import json
        def event(kind, **fields):
            print(json.dumps(dict(protocol_version=1,run_id='test',type=kind,**fields)),flush=True)
        def progress(done,total,unit,phase):
            event('stage_progress',stage='asr',completed=done,total=total,progress_unit=unit,progress_phase=phase)
        event('stage_started',stage='asr')
        progress(0,2,'audio_windows','windows')
        event('stage_started',stage='asr',process_group_id=2147483647)
        event('stage_completed',stage='asr',process_group_id=2147483647,process_group_finished=True)
        progress(0,1,'speech_clips','window_1')
        progress(1,1,'speech_clips','window_1')
        progress(1,2,'audio_windows','windows')
        event('stage_completed',stage='asr')
        event('completed')
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        let progress = expectation(description: "Counted progress")
        progress.expectedFulfillmentCount = 4
        let result = try await WorkerProcess(runID: "test").run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                         arguments: [script.path], directory: directory) { event in
            if event.type == "stage_progress" { progress.fulfill() }
        }
        await fulfillment(of: [progress], timeout: 1)
        XCTAssertNil(result.error)
        XCTAssertTrue(result.cleanupConfirmed)
    }

    func testMalformedRegressingWrongStageAndTerminalProgressAreRejected() async throws {
        for mutation in ["completed=True", "total=0", "completed=3", "total=1000000001", "progress_phase='bad phase'",
                         "progress_unit='note_groups'", "stage='summary'", "run_id='other'", "completed=-1",
                         "total=3", "progress_phase=''", "progress_phase='windows\\n'", "process_group_id=3", "completed=0", "terminal=True", "finished=True"] {
            let (directory, script) = try fixture("""
            import json
            def event(kind, **fields):
                print(json.dumps(dict(protocol_version=1,run_id='test',type=kind,**fields)),flush=True)
            event('stage_started',stage='asr')
            value=dict(protocol_version=1,run_id='test',type='stage_progress',stage='asr',completed=1,total=2,
                       progress_unit='audio_windows',progress_phase='windows')
            print(json.dumps(value),flush=True)
            changes=dict(\(mutation))
            if changes.pop('terminal',False): event('completed')
            if changes.pop('finished',False): event('stage_completed',stage='asr')
            value.update(changes)
            print(json.dumps(value),flush=True)
            """)
            defer { try? FileManager.default.removeItem(at: directory) }
            let result = try await WorkerProcess(runID: "test").run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                             arguments: [script.path], directory: directory) { _ in }
            XCTAssertNotNil(result.error, mutation)
            XCTAssertTrue(result.cleanupConfirmed, mutation)
        }
    }
}
