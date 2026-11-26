import Foundation

struct QiCandidate: Equatable {
    var text: String
    var comment: String
}

struct QiRimeSnapshot: Equatable {
    var committed: String
    var preedit: String
    var candidates: [QiCandidate]
    var highlightedIndex: Int
    var isComposing: Bool
    var schema: QiScheme
    var asciiMode: Bool
}

// C1, C2: iOS 键盘扩展直接调用 librime C API，加载随应用打包的雾凇词库与 qi_switch.lua。
final class QiRimeEngine {
    static let shared = QiRimeEngine()

    private let api: UnsafeMutablePointer<RimeApi>
    private var started = false
    private var session: RimeSessionId = 0

    private init() {
        api = rime_get_api()!
    }

    func startIfNeeded() {
        guard !started else {
            ensureSession()
            return
        }
        QiStore.prepareRimeData()
        guard let sharedURL = QiStore.sharedSupportDir else { return }
        start(sharedURL: sharedURL, userURL: QiStore.rimeUserDir)
    }

    func start(sharedURL: URL, userURL: URL) {
        guard !started else {
            ensureSession()
            return
        }
        let prebuiltURL = sharedURL.appendingPathComponent("build")
        let stagingURL = userURL.appendingPathComponent("build")
        try? FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        var traits = RimeTraits()
        traits.data_size = Int32(MemoryLayout<RimeTraits>.size - MemoryLayout<Int32>.size)
        traits.min_log_level = 2

        let sharedPath = strdup(sharedURL.path)
        let userPath = strdup(userURL.path)
        let prebuiltPath = strdup(prebuiltURL.path)
        let stagingPath = strdup(stagingURL.path)
        let distName = strdup("一炁输入法")
        let distCode = strdup("YiQi")
        let distVer = strdup(QiUpdater.current)
        let appName = strdup("rime.yiqi")
        defer {
            free(sharedPath); free(userPath); free(prebuiltPath); free(stagingPath)
            free(distName); free(distCode); free(distVer); free(appName)
        }

        traits.shared_data_dir = UnsafePointer(sharedPath)
        traits.user_data_dir = UnsafePointer(userPath)
        traits.prebuilt_data_dir = UnsafePointer(prebuiltPath)
        traits.staging_dir = UnsafePointer(stagingPath)
        traits.distribution_name = UnsafePointer(distName)
        traits.distribution_code_name = UnsafePointer(distCode)
        traits.distribution_version = UnsafePointer(distVer)
        traits.app_name = UnsafePointer(appName)

        api.pointee.setup(&traits)
        api.pointee.initialize(&traits)
        let prebuiltSchema = prebuiltURL.appendingPathComponent("rime_frost_double_pinyin_flypy.schema.yaml")
        let stagedSchema = stagingURL.appendingPathComponent("rime_frost_double_pinyin_flypy.schema.yaml")
        if !FileManager.default.fileExists(atPath: prebuiltSchema.path) &&
            !FileManager.default.fileExists(atPath: stagedSchema.path) {
            _ = api.pointee.start_maintenance(0)
            api.pointee.join_maintenance_thread()
        }
        started = true
        ensureSession()
        syncSchemaFromStore()
    }

    // C9: 请 Rime 做一次「同步用户资料」：导出本机词库快照，并合并 sync/ 下其他设备的快照。
    // 正在输入时不做（会重启引擎）；返回 false 表示稍后再试。
    func syncUserData() -> Bool {
        guard started, !snapshot().isComposing else { return false }
        _ = api.pointee.destroy_session(session)
        api.pointee.finalize()
        started = false
        session = 0
        api.pointee.deployer_initialize(nil)
        let ok = api.pointee.sync_user_data() != 0
        api.pointee.join_maintenance_thread()
        api.pointee.finalize()
        startIfNeeded()
        return ok
    }

    private func ensureSession() {
        if session == 0 || api.pointee.find_session(session) == 0 {
            session = api.pointee.create_session()
        }
    }

    func syncSchemaFromStore() {
        guard started else { return }
        ensureSession()
        let want = QiStore.scheme
        if currentSchema() != want {
            _ = want.rawValue.withCString { api.pointee.select_schema(session, $0) }
        }
    }

    func currentSchema() -> QiScheme {
        guard started, session != 0 else { return QiStore.scheme }
        var status = RimeStatus()
        status.data_size = Int32(MemoryLayout<RimeStatus>.size - MemoryLayout<Int32>.size)
        defer { _ = api.pointee.free_status(&status) }
        if api.pointee.get_status(session, &status) != 0, let ptr = status.schema_id {
            let id = String(cString: ptr)
            if let sc = QiScheme(rawValue: id) { return sc }
        }
        return QiStore.scheme
    }

    var asciiMode: Bool {
        guard started, session != 0 else { return false }
        return api.pointee.get_option(session, "ascii_mode") != 0
    }

    @discardableResult
    func toggleAsciiMode() -> QiRimeSnapshot {
        startIfNeeded()
        api.pointee.set_option(session, "ascii_mode", asciiMode ? 0 : 1)
        return snapshot(committed: "")
    }

    // C2: 切换小鹤双拼 / 全拼，保留正在输入的拼音按新方式重新解读。
    @discardableResult
    func switchScheme(_ target: QiScheme) -> QiRimeSnapshot {
        startIfNeeded()
        QiStore.requestScheme(target)
        let prevInput = api.pointee.get_input(session).map { String(cString: $0) } ?? ""
        _ = target.rawValue.withCString { api.pointee.select_schema(session, $0) }
        if !prevInput.isEmpty {
            _ = prevInput.withCString { api.pointee.set_input(session, $0) }
        }
        return snapshot(committed: "")
    }

    func processKey(code: Int32, mask: Int32 = 0) -> (handled: Bool, snapshot: QiRimeSnapshot) {
        startIfNeeded()
        let handled = api.pointee.process_key(session, code, mask) != 0
        let committed = consumeCommit()
        return (handled, snapshot(committed: committed))
    }

    func selectCandidate(at index: Int) -> QiRimeSnapshot {
        startIfNeeded()
        _ = api.pointee.select_candidate(session, index)
        let committed = consumeCommit()
        return snapshot(committed: committed)
    }

    func commitComposition() -> QiRimeSnapshot {
        startIfNeeded()
        _ = api.pointee.commit_composition(session)
        let committed = consumeCommit()
        return snapshot(committed: committed)
    }

    func clearComposition() -> QiRimeSnapshot {
        startIfNeeded()
        api.pointee.clear_composition(session)
        return snapshot(committed: "")
    }

    private func consumeCommit() -> String {
        var commit = RimeCommit()
        commit.data_size = Int32(MemoryLayout<RimeCommit>.size - MemoryLayout<Int32>.size)
        defer { _ = api.pointee.free_commit(&commit) }
        if api.pointee.get_commit(session, &commit) != 0, let text = commit.text {
            return String(cString: text)
        }
        return ""
    }

    func snapshot(committed: String = "") -> QiRimeSnapshot {
        guard started, session != 0 else {
            return QiRimeSnapshot(committed: committed, preedit: "", candidates: [],
                                  highlightedIndex: 0, isComposing: false,
                                  schema: QiStore.scheme, asciiMode: false)
        }
        var ctx = RimeContext()
        ctx.data_size = Int32(MemoryLayout<RimeContext>.size - MemoryLayout<Int32>.size)
        defer { _ = api.pointee.free_context(&ctx) }

        var preedit = ""
        var highlighted = 0
        var cands: [QiCandidate] = []

        if api.pointee.get_context(session, &ctx) != 0 {
            if let p = ctx.composition.preedit {
                preedit = String(cString: p)
            }
            highlighted = Int(ctx.menu.highlighted_candidate_index)
        }

        // 读取最多 40 个候选词供横向滑动与展开面板使用
        var iter = RimeCandidateListIterator()
        if api.pointee.candidate_list_begin(session, &iter) != 0 {
            defer { api.pointee.candidate_list_end(&iter) }
            while cands.count < 40 && api.pointee.candidate_list_next(&iter) != 0 {
                let text = iter.candidate.text.map { String(cString: $0) } ?? ""
                let comment = iter.candidate.comment.map { String(cString: $0) } ?? ""
                if !text.isEmpty {
                    cands.append(QiCandidate(text: text, comment: comment))
                }
            }
        }

        return QiRimeSnapshot(
            committed: committed,
            preedit: preedit,
            candidates: cands,
            highlightedIndex: highlighted,
            isComposing: !preedit.isEmpty || !cands.isEmpty,
            schema: currentSchema(),
            asciiMode: asciiMode
        )
    }
}
