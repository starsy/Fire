//
//  Fire.swift
//  Fire
//
//  Created by 虚幻 on 2019/9/15.
//  Copyright © 2019 qwertyyb. All rights reserved.
//

import Cocoa
import InputMethodKit
import SQLite3
import Sparkle
import Defaults

let kConnectionName = "Fire_1_Connection"

extension UserDefaults {
    @objc dynamic var codeMode: Int {
        get {
            return integer(forKey: "codeMode")
        }
        set {
            set(newValue, forKey: "codeMode")
        }
    }
}

internal let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

class Fire: NSObject {
    static let candidateSelected = Notification.Name("Fire.candidateSelected")
    static let candidateListUpdated = Notification.Name("Fire.candidateListUpdated")
    static let nextPageBtnTapped = Notification.Name("Fire.nextPageBtnTapped")
    static let prevPageBtnTapped = Notification.Name("Fire.prevPageBtnTapped")

    private var database: OpaquePointer?
    private var queryStatement: OpaquePointer?
    private var preferencesObserver: Defaults.Observation!

    let appSettingCache = ApplicationSettingCache()

    var inputMode: InputMode = .zhhans

    override init() {
        super.init()

        preferencesObserver = Defaults.observe(keys: .codeMode, .candidateCount) { () in
            self.prepareStatement()
        }
    }

    deinit {
        preferencesObserver.invalidate()
        close()
    }

    private func getStatementSql() -> String {
        let candidateCount = Defaults[.candidateCount]
        // 比显示的候选词数量多查一个，以此判断有没有下一页
        var sql = """
            select
                max(wbcode), text, type, min(query) as query
                from wb_py_dict
                where query like :query
                group by text
                order by query, id
                limit :offset, \(candidateCount + 1)
        """
        let codeMode = Defaults[.codeMode]
        if codeMode != .wubiPinyin {
            sql = """
                select
                  min(code) as wbcode,
                  text,
                  '\(codeMode == .wubi ? "wb" : "py")' as type,
                  min(code) as query
                from \(codeMode == .wubi ? "wb_dict" : "py_dict")
                where code like :query
                group by text
                order by query, id
                limit :offset, \(candidateCount + 1)
            """
        }
        print(sql)
        return sql
    }

    func close() {
        queryStatement = nil
        sqlite3_close_v2(database)
        sqlite3_shutdown()
        database = nil
    }

    func prepareStatement() {
        sqlite3_open_v2(getDatabaseURL().path, &database, SQLITE_OPEN_READWRITE, nil)
        if sqlite3_prepare_v2(database, getStatementSql(), -1, &queryStatement, nil) == SQLITE_OK {
            print("prepare ok")
            print(sqlite3_bind_parameter_index(queryStatement, ":code"))
            print(sqlite3_bind_parameter_count(queryStatement))
        } else if let err = sqlite3_errmsg(database) {
            print("prepare fail: \(err)")
        }
    }

    private func getQueryFromOrigin(_ origin: String) -> String {
        if origin.isEmpty {
            return origin
        }

        if !Defaults[.zKeyQuery] {
            return origin
        }

        // z键查询，z不能放在首位
        let first = origin.first!
        return String(first) + (String(origin.suffix(origin.count - 1))
            .replacingOccurrences(of: "z", with: "_"))
    }

    var server: IMKServer = IMKServer.init(name: kConnectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
    func getCandidates(origin: String = String(), page: Int = 1) -> (candidates: [Candidate], hasNext: Bool) {
        if origin.count <= 0 {
            return ([], false)
        }
        let query = getQueryFromOrigin(origin)
        NSLog("get local candidate, origin: \(origin), query: ", query)
        var candidates: [Candidate] = []
        sqlite3_reset(queryStatement)
        sqlite3_clear_bindings(queryStatement)
        sqlite3_bind_text(queryStatement,
                        sqlite3_bind_parameter_index(queryStatement, ":code"),
                        origin, -1,
                        SQLITE_TRANSIENT
        )
        sqlite3_bind_text(queryStatement,
                          sqlite3_bind_parameter_index(queryStatement, ":query"),
                          "\(query)%", -1,
                          SQLITE_TRANSIENT
        )
        sqlite3_bind_int(queryStatement,
                         sqlite3_bind_parameter_index(queryStatement, ":offset"),
                         Int32((page - 1) * Defaults[.candidateCount])
        )
        let strp = sqlite3_expanded_sql(queryStatement)!
        print(String(cString: strp))
        while sqlite3_step(queryStatement) == SQLITE_ROW {
            let code = String.init(cString: sqlite3_column_text(queryStatement, 0))
            let text = String.init(cString: sqlite3_column_text(queryStatement, 1))
            let type = String.init(cString: sqlite3_column_text(queryStatement, 2))
            let candidate = Candidate(code: code, text: text, type: type)
            candidates.append(candidate)
        }
        let count = Defaults[.candidateCount]
        let allCount = candidates.count
        candidates = Array(candidates.prefix(count))

        if candidates.isEmpty {
            candidates.append(Candidate(code: origin, text: origin, type: "wb"))
        }

        return (candidates, hasNext: allCount > count)
    }

    func setFirstCandidate(wbcode: String, candidate: Candidate) -> Bool {
        var sql = """
            insert into wb_py_dict(id, wbcode, text, type, query)
            values (
                (select MIN(id) - 1 from wb_py_dict), :code, :text, :type, :code
            );
        """
        let codeMode = Defaults[.codeMode]
        if codeMode != .wubiPinyin {
            sql = """
                insert into \(codeMode == .wubi ? "wb_dict" : "py_dict")(id, code, text)
                values(
                    (select MIN(id) - 1 from \(codeMode == .wubi ? "wb_dict" : "py_dict")),
                    :code,
                    :text
                );
            """
        }
        var insertStatement: OpaquePointer?
        if sqlite3_prepare_v2(database, sql, -1, &insertStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(insertStatement,
                sqlite3_bind_parameter_index(insertStatement, ":code"),
                              wbcode, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insertStatement,
                              sqlite3_bind_parameter_index(insertStatement, ":text"),
                              candidate.text, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insertStatement,
                              sqlite3_bind_parameter_index(insertStatement, ":type"),
                              "wb", -1, SQLITE_TRANSIENT)
            let strp = sqlite3_expanded_sql(queryStatement)!
            print(String(cString: strp))
            if sqlite3_step(insertStatement) == SQLITE_DONE {
                sqlite3_finalize(insertStatement)
                insertStatement = nil
                return true
            } else {
                print("errmsg: \(String(cString: sqlite3_errmsg(database)!))")
                return false
            }
        } else {
            print("prepare_errmsg: \(String(cString: sqlite3_errmsg(database)!))")
        }
        return false
    }

    static let shared = Fire()
}
