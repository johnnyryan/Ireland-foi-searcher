// FOI Search — full-text search of every PDF linked as "FOI Request Files"
// By Johnny Ryan. Free and open source under the MIT License (see LICENSE).
// SPDX-License-Identifier: MIT
//
// on publicinformation.ie, with an optional date range.
//
// Native macOS app: AppKit + WebKit for the window, PDFKit for text,
// Vision for OCR of scanned pages, the system SQLite (FTS5) for the index.

import Cocoa
import CryptoKit
import PDFKit
import SQLite3
import Vision
import WebKit

let datasetURL = URL(string: "https://publicinformation.ie/api/data/foi.json")!
let appUA = "Mozilla/5.0 (FOI-search research tool)"
let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

let dataDir: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("FOI Search", isDirectory: true)
}()
let pdfDir = dataDir.appendingPathComponent("pdfs", isDirectory: true)

// MARK: - SQLite

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct DBError: Error, CustomStringConvertible { let description: String }

final class DB: @unchecked Sendable {
    private var h: OpaquePointer?
    private let lock = NSRecursiveLock()

    init(path: String) throws {
        if sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw DBError(description: "Cannot open database at \(path)")
        }
        sqlite3_busy_timeout(h, 30000)
        try exec("PRAGMA journal_mode=WAL")
    }

    func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(h, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DBError(description: msg)
        }
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer? {
        var st: OpaquePointer?
        if sqlite3_prepare_v2(h, sql, -1, &st, nil) != SQLITE_OK {
            throw DBError(description: String(cString: sqlite3_errmsg(h)))
        }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(st, idx)
            case let v as Int: sqlite3_bind_int64(st, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(st, idx, v)
            case let v as Double: sqlite3_bind_double(st, idx, v)
            case let v as Bool: sqlite3_bind_int(st, idx, v ? 1 : 0)
            case let v as String: sqlite3_bind_text(st, idx, v, -1, SQLITE_TRANSIENT)
            default: sqlite3_bind_text(st, idx, "\(a!)", -1, SQLITE_TRANSIENT)
            }
        }
        return st
    }

    @discardableResult
    func run(_ sql: String, _ args: [Any?] = []) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        let rc = sqlite3_step(st)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            throw DBError(description: String(cString: sqlite3_errmsg(h)))
        }
        return sqlite3_last_insert_rowid(h)
    }

    func query(_ sql: String, _ args: [Any?] = []) throws -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        var rows: [[String: Any]] = []
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw DBError(description: String(cString: sqlite3_errmsg(h))) }
            var row: [String: Any] = [:]
            for c in 0..<sqlite3_column_count(st) {
                let name = String(cString: sqlite3_column_name(st, c))
                switch sqlite3_column_type(st, c) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(st, c))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(st, c)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(st, c))
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }

    func scalar(_ sql: String, _ args: [Any?] = []) -> Any? {
        (try? query(sql, args))?.first?.values.first
    }

    func transaction(_ body: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }
}

let schema = """
CREATE TABLE IF NOT EXISTS docs (
  id INTEGER PRIMARY KEY, url TEXT UNIQUE, bodies TEXT, body_slugs TEXT, n_records INTEGER,
  date_min TEXT, date_max TEXT, status TEXT, error TEXT, file TEXT, pages INTEGER,
  text_chars INTEGER, ocr INTEGER DEFAULT 0, indexed_at TEXT);
CREATE TABLE IF NOT EXISTS pages (id INTEGER PRIMARY KEY, doc_id INTEGER, page INTEGER,
  date_min TEXT, date_max TEXT, dates TEXT);
CREATE VIRTUAL TABLE IF NOT EXISTS pages_fts USING fts5(text, tokenize="unicode61 remove_diacritics 2");
CREATE TABLE IF NOT EXISTS records (rid INTEGER PRIMARY KEY, doc_url TEXT, body TEXT, slug TEXT, ref TEXT,
  decision_date TEXT, date_received TEXT, requester_type TEXT, decision_status TEXT, description TEXT, date_iso TEXT);
CREATE VIRTUAL TABLE IF NOT EXISTS records_fts USING fts5(description, ref, body, tokenize="unicode61 remove_diacritics 2");
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
CREATE INDEX IF NOT EXISTS pages_doc ON pages(doc_id);
CREATE INDEX IF NOT EXISTS records_url ON records(doc_url);
"""

// MARK: - Dates

let monthNames: [String: Int] = {
    var m: [String: Int] = [:]
    for (i, n) in ["january", "february", "march", "april", "may", "june", "july", "august",
                   "september", "october", "november", "december"].enumerated() {
        m[n] = i + 1; m[String(n.prefix(3))] = i + 1
    }
    m["sept"] = 9
    return m
}()
let gregorian = Calendar(identifier: .gregorian)
let maxYear = gregorian.component(.year, from: Date()) + 1

func makeDate(_ y0: Int, _ m: Int, _ d: Int) -> String? {
    let y = y0 < 100 ? y0 + 2000 : y0
    guard (1998...maxYear).contains(y), (1...12).contains(m), d >= 1 else { return nil }
    let dc = DateComponents(calendar: gregorian, year: y, month: m, day: d)
    guard dc.isValidDate else { return nil }
    return String(format: "%04d-%02d-%02d", y, m, d)
}

let dateRegexes: [(NSRegularExpression, ([String]) -> String?)] = [
    (try! NSRegularExpression(pattern: #"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#),
     { g in makeDate(Int(g[0])!, Int(g[1])!, Int(g[2])!) }),
    (try! NSRegularExpression(pattern: #"\b(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{4}|\d{2})\b"#),
     { g in makeDate(Int(g[2])!, Int(g[1])!, Int(g[0])!) }),
    (try! NSRegularExpression(pattern: #"\b(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]{3,9})\.?,?\s+(\d{4})\b"#),
     { g in makeDate(Int(g[2])!, monthNames[g[1].lowercased()] ?? 0, Int(g[0])!) }),
    (try! NSRegularExpression(pattern: #"\b([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\b"#),
     { g in makeDate(Int(g[2])!, monthNames[g[0].lowercased()] ?? 0, Int(g[1])!) }),
]

/// All plausible dates in the text as ISO strings (Irish day/month/year order).
func findDates(_ text: String) -> Set<String> {
    var out = Set<String>()
    let ns = text as NSString
    for (rx, fn) in dateRegexes {
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let g = (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
            if let d = fn(g) { out.insert(d) }
        }
    }
    return out
}

func firstDate(_ s: String?) -> String? { s.flatMap { findDates($0).min() } }

// MARK: - Networking

final class InsecureDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// One request at a time per host, so council firewalls don't block us.
actor HostGate {
    private var busy = Set<String>()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    func acquire(_ host: String) async {
        if busy.contains(host) {
            await withCheckedContinuation { c in waiters[host, default: []].append(c) }
        } else {
            busy.insert(host)
        }
    }
    func release(_ host: String) {
        if var w = waiters[host], !w.isEmpty {
            let c = w.removeFirst(); waiters[host] = w; c.resume()
        } else {
            busy.remove(host)
        }
    }
}

struct HTTPError: Error, CustomStringConvertible { let code: Int; var description: String { "HTTP \(code)" } }

final class Fetcher: @unchecked Sendable {
    let secure: URLSession
    let insecure: URLSession
    let gate = HostGate()
    private let insecureDelegate = InsecureDelegate()

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 600
        cfg.httpMaximumConnectionsPerHost = 2
        secure = URLSession(configuration: cfg)
        insecure = URLSession(configuration: cfg, delegate: insecureDelegate, delegateQueue: nil)
    }

    static func encode(_ raw: String) -> URL? {
        let allowed = CharacterSet.urlQueryAllowed.union(CharacterSet(charactersIn: "#%"))
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: s) ?? URL(string: s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s)
    }

    private func once(_ url: URL, ua: String, session: URLSession) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/pdf,*/*", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 { throw HTTPError(code: http.statusCode) }
        return data
    }

    private func attempt(_ url: URL) async throws -> Data {
        do {
            return try await once(url, ua: appUA, session: secure)
        } catch let e as HTTPError where [401, 403, 406, 429].contains(e.code) {
            return try await once(url, ua: browserUA, session: secure)
        } catch let e as URLError where [.serverCertificateUntrusted, .serverCertificateHasBadDate,
                                         .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
                                         .secureConnectionFailed].contains(e.code) {
            // public documents only: tolerate council sites with broken certificate chains
            return try await once(url, ua: browserUA, session: insecure)
        }
    }

    func get(_ raw: String, politeDelay: Bool = true) async throws -> Data {
        guard let url = Fetcher.encode(raw) else { throw DBError(description: "Malformed link") }
        let host = (url.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        await gate.acquire(host)
        let result: Result<Data, Error>
        do { result = .success(try await attempt(url)) } catch { result = .failure(error) }
        if politeDelay { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        await gate.release(host)
        return try result.get()
    }
}

// MARK: - PDF text

func ocrPage(_ page: PDFPage) -> String {
    let bounds = page.bounds(for: .mediaBox)
    let scale = min(2.5, 2400 / max(bounds.width, bounds.height))
    let img = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
    guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.recognitionLanguages = ["en-GB", "en-US"]
    req.usesLanguageCorrection = true
    try? VNImageRequestHandler(cgImage: cg).perform([req])
    return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

/// Page texts for a PDF; scanned PDFs (little or no text layer) are OCR'd with Vision.
func extractPages(_ doc: PDFDocument) -> (pages: [String], ocr: Bool) {
    var pages: [String] = []
    for i in 0..<doc.pageCount { pages.append(doc.page(at: i)?.string ?? "") }
    let chars = pages.reduce(0) { $0 + $1.trimmingCharacters(in: .whitespacesAndNewlines).count }
    guard doc.pageCount > 0, chars < 50 * doc.pageCount else { return (pages, false) }
    for i in 0..<doc.pageCount where pages[i].trimmingCharacters(in: .whitespacesAndNewlines).count < 50 {
        if let p = doc.page(at: i) { pages[i] = ocrPage(p) }
    }
    return (pages, true)
}

func fileName(for url: String) -> String {
    let h = Insecure.SHA1.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    return String(h.prefix(16)) + ".pdf"
}

// MARK: - Index

struct UpdateState { var running = false; var done = 0; var total = 0; var msg = "" }

final class Index: @unchecked Sendable {
    let db: DB
    let fetcher = Fetcher()
    private let stateLock = NSLock()
    private var _state = UpdateState()
    var state: UpdateState { stateLock.lock(); defer { stateLock.unlock() }; return _state }
    var onProgress: (() -> Void)?

    init() throws {
        try FileManager.default.createDirectory(at: pdfDir, withIntermediateDirectories: true)
        db = try DB(path: dataDir.appendingPathComponent("index.sqlite").path)
        // older index without the requests search: rebuild the requests table on next update
        let cols = ((try? db.query("PRAGMA table_info(records)")) ?? []).compactMap { $0["name"] as? String }
        if !cols.isEmpty && !cols.contains("date_iso") {
            try db.exec("DROP TABLE records; DELETE FROM meta WHERE k='last_update'")
        }
        try db.exec(schema)
    }

    private func setState(_ f: (inout UpdateState) -> Void) {
        stateLock.lock(); f(&_state); stateLock.unlock()
        onProgress?()
    }

    func meta(_ k: String) -> String? { db.scalar("SELECT v FROM meta WHERE k=?", [k]) as? String }
    func setMeta(_ k: String, _ v: String) { try? db.run("INSERT OR REPLACE INTO meta VALUES(?,?)", [k, v]) }

    func statsLine() -> String {
        var s: [String: Int] = [:]
        for r in (try? db.query("SELECT status, COUNT(*) n FROM docs GROUP BY status")) ?? [] {
            s[r["status"] as? String ?? ""] = r["n"] as? Int ?? 0
        }
        let pages = db.scalar("SELECT COUNT(*) FROM pages") as? Int ?? 0
        let nf = NumberFormatter(); nf.numberStyle = .decimal
        func f(_ n: Int) -> String { nf.string(from: NSNumber(value: n)) ?? "\(n)" }
        var parts = ["\(f(s["ok"] ?? 0)) PDFs searchable (\(f(pages)) pages)"]
        let bad = (s["error"] ?? 0) + (s["notpdf"] ?? 0)
        if bad > 0 { parts.append("\(bad) could not be downloaded") }
        if (s["empty"] ?? 0) > 0 { parts.append("\(s["empty"]!) with no readable text") }
        if (s["pending"] ?? 0) > 0 { parts.append("\(f(s["pending"]!)) still to download") }
        return parts.joined(separator: " · ")
    }

    // ---- update

    func update() async {
        if state.running { return }
        setState { $0 = UpdateState(running: true, done: 0, total: 0, msg: "Fetching the FOI dataset…") }
        do {
            try await loadDataset()
            let todo = try db.query("SELECT url FROM docs WHERE status IN ('pending','error','notpdf')")
                .compactMap { $0["url"] as? String }
            setState { $0.total = todo.count; $0.msg = "Downloading and indexing PDFs…" }
            await withTaskGroup(of: Void.self) { group in
                var it = todo.makeIterator()
                func next() -> Bool {
                    guard let u = it.next() else { return false }
                    group.addTask { [self] in
                        await processDoc(u)
                        setState { $0.done += 1 }
                    }
                    return true
                }
                for _ in 0..<6 { if !next() { break } }
                for await _ in group { _ = next() }
            }
            setMeta("last_update", ISO8601DateFormatter().string(from: Date()))
            setState { $0.msg = "Up to date." }
        } catch {
            setState { $0.msg = "Update failed: \(error.localizedDescription)" }
        }
        setState { $0.running = false }
    }

    private func loadDataset() async throws {
        let data = try await fetcher.get(datasetURL.absoluteString, politeDelay: false)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recs = obj["records"] as? [[String: Any]] else {
            throw DBError(description: "Unexpected dataset format")
        }
        struct Agg { var bodies = Set<String>(); var slugs = Set<String>(); var n = 0; var dates: [String] = [] }
        var docs: [String: Agg] = [:]
        func s(_ r: [String: Any], _ k: String) -> String? { r[k] as? String }
        for r in recs {
            let url = (s(r, "file_url") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { continue }
            let path = (URL(string: url)?.path ?? url).lowercased()
            guard (s(r, "file_type") ?? "").lowercased() == "pdf" || path.hasSuffix(".pdf") else { continue }
            var a = docs[url] ?? Agg()
            a.bodies.insert(s(r, "name") ?? s(r, "slug") ?? "")
            a.slugs.insert(s(r, "slug") ?? "")
            a.n += 1
            for k in ["decision_date", "date_received"] { if let d = firstDate(s(r, k)) { a.dates.append(d) } }
            docs[url] = a
        }
        func json(_ set: Set<String>) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: set.sorted()), encoding: .utf8)!
        }
        try db.transaction {
            try db.run("DELETE FROM records")
            try db.run("DELETE FROM records_fts")
            for r in recs {
                let date = firstDate(s(r, "decision_date")) ?? firstDate(s(r, "date_received"))
                let rid = try db.run("""
                    INSERT INTO records(doc_url,body,slug,ref,decision_date,date_received,requester_type,
                      decision_status,description,date_iso) VALUES (?,?,?,?,?,?,?,?,?,?)
                    """,
                    [(s(r, "file_url") ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                     s(r, "name"), s(r, "slug"), s(r, "foi_reference_id"), s(r, "decision_date"),
                     s(r, "date_received"), s(r, "requester_type"), s(r, "decision_status"),
                     s(r, "request_description"), date])
                try db.run("INSERT INTO records_fts(rowid,description,ref,body) VALUES(?,?,?,?)",
                           [rid, s(r, "request_description") ?? "", s(r, "foi_reference_id") ?? "", s(r, "name") ?? ""])
            }
            for (url, a) in docs {
                try db.run("""
                    INSERT INTO docs(url,bodies,body_slugs,n_records,date_min,date_max,status,file)
                    VALUES(?,?,?,?,?,?,'pending',?)
                    ON CONFLICT(url) DO UPDATE SET bodies=excluded.bodies, body_slugs=excluded.body_slugs,
                      n_records=excluded.n_records, date_min=excluded.date_min, date_max=excluded.date_max
                    """, [url, json(a.bodies), json(a.slugs), a.n, a.dates.min(), a.dates.max(), fileName(for: url)])
            }
        }
        setMeta("dataset_fetched", ISO8601DateFormatter().string(from: Date()))
    }

    private func processDoc(_ url: String) async {
        let path = pdfDir.appendingPathComponent(fileName(for: url))
        var status = "ok", err: String? = nil
        var pages: [String] = [], ocr = false
        do {
            var data: Data
            if let d = try? Data(contentsOf: path), !d.isEmpty {
                data = d
            } else {
                data = try await fetcher.get(url)
                let head = String(decoding: data.prefix(1024), as: UTF8.self)
                guard head.contains("%PDF") else {
                    throw DBError(description: "The link did not return a PDF (it may have moved)")
                }
                try data.write(to: path, options: .atomic)
            }
            guard let doc = PDFDocument(data: data) else { throw DBError(description: "Could not read this PDF") }
            (pages, ocr) = extractPages(doc)
            if pages.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                status = "empty"; err = "No readable text"
            }
            data = Data()
        } catch {
            status = (error as? DBError)?.description.contains("PDF") == true ? "notpdf" : "error"
            err = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
            if let u = error as? URLError { err = u.localizedDescription }
        }
        store(url: url, status: status, error: err, pages: pages, ocr: ocr)
    }

    private func store(url: String, status: String, error: String?, pages: [String], ocr: Bool) {
        try? db.transaction {
            guard let docId = db.scalar("SELECT id FROM docs WHERE url=?", [url]) as? Int else { return }
            if status != "ok" && status != "empty" {
                // keep any previously indexed text if a re-download fails
                if (db.scalar("SELECT COUNT(*) FROM pages WHERE doc_id=?", [docId]) as? Int ?? 0) > 0 { return }
                try db.run("UPDATE docs SET status=?, error=? WHERE id=?", [status, error, docId])
                return
            }
            try db.run("DELETE FROM pages_fts WHERE rowid IN (SELECT id FROM pages WHERE doc_id=?)", [docId])
            try db.run("DELETE FROM pages WHERE doc_id=?", [docId])
            var chars = 0
            for (i, text) in pages.enumerated() {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { continue }
                chars += t.count
                let ds = findDates(text).sorted()
                let dj = String(data: try JSONSerialization.data(withJSONObject: ds), encoding: .utf8)!
                let pid = try db.run("INSERT INTO pages(doc_id,page,date_min,date_max,dates) VALUES(?,?,?,?,?)",
                                     [docId, i + 1, ds.first, ds.last, dj])
                try db.run("INSERT INTO pages_fts(rowid,text) VALUES(?,?)", [pid, text])
            }
            try db.run("UPDATE docs SET status=?, error=?, pages=?, text_chars=?, ocr=?, indexed_at=? WHERE id=?",
                       [status, error, pages.count, chars, ocr ? 1 : 0,
                        ISO8601DateFormatter().string(from: Date()), docId])
        }
    }

    // ---- search

    static func ftsQuery(_ q: String) -> String {
        let rx = try! NSRegularExpression(pattern: #""[^"]*"|\S+"#)
        let ns = q as NSString
        let word = try! NSRegularExpression(pattern: #"^\w+\*?$"#)
        return rx.matches(in: q, range: NSRange(location: 0, length: ns.length)).map { m -> String in
            let p = ns.substring(with: m.range)
            if p.hasPrefix("\"") || ["AND", "OR", "NOT", "(", ")"].contains(p) || p.hasPrefix("NEAR(") { return p }
            if word.firstMatch(in: p, range: NSRange(location: 0, length: (p as NSString).length)) != nil { return p }
            let star = p.hasSuffix("*")
            let core = p.trimmingCharacters(in: CharacterSet(charactersIn: "*")).replacingOccurrences(of: "\"", with: "")
            return "\"\(core)\"" + (star ? "*" : "")
        }.joined(separator: " ")
    }

    static func terms(_ q: String) -> [String] {
        let ns = q as NSString
        let prx = try! NSRegularExpression(pattern: #""([^"]+)""#)
        let phrases = prx.matches(in: q, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        var rest = prx.stringByReplacingMatches(in: q, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        rest = rest.replacingOccurrences(of: #"NEAR\(|\)|,\s*\d+"#, with: " ", options: .regularExpression)
        let wrx = try! NSRegularExpression(pattern: #"[\w*]+"#)
        let rns = rest as NSString
        let words = wrx.matches(in: rest, range: NSRange(location: 0, length: rns.length))
            .map { rns.substring(with: $0.range).trimmingCharacters(in: CharacterSet(charactersIn: "*")) }
            .filter { !["AND", "OR", "NOT", ""].contains($0) }
        return phrases + words
    }

    static let ws = try! NSRegularExpression(pattern: #"\s+"#)

    static func snippets(_ text: String, _ terms: [String], width: Int = 160, maxN: Int = 3) -> [[String: Any]] {
        let flat = ws.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: " ") as NSString
        let opts: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var spans: [NSRange] = []
        for t in terms {
            let term = ws.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: " ")
            var from = 0
            while from < flat.length {
                let r = flat.range(of: term, options: opts, range: NSRange(location: from, length: flat.length - from))
                if r.location == NSNotFound { break }
                let before = r.location > 0 ? flat.character(at: r.location - 1) : 32
                if !(CharacterSet.alphanumerics.contains(Unicode.Scalar(before) ?? " ")) { spans.append(r) }
                from = r.location + max(1, r.length)
            }
        }
        spans.sort { $0.location < $1.location }
        var out: [[String: Any]] = []
        var lastEnd = -1
        for s in spans where s.location >= lastEnd {
            let a = max(0, s.location - width), b = min(flat.length, NSMaxRange(s) + width)
            let marks = spans.filter { $0.location >= a && NSMaxRange($0) <= b }.map { [$0.location - a, NSMaxRange($0) - a] }
            out.append(["text": flat.substring(with: NSRange(location: a, length: b - a)),
                        "pre": a > 0, "post": b < flat.length, "marks": marks])
            lastEnd = b
            if out.count >= maxN { break }
        }
        if out.isEmpty {
            let n = min(flat.length, width * 2)
            out.append(["text": flat.substring(to: n), "pre": false, "post": flat.length > n, "marks": [[Int]]()])
        }
        return out
    }

    static func snippetText(_ s: [String: Any]) -> String {
        let t = s["text"] as! NSString
        var pos = 0, buf = ""
        for m in s["marks"] as! [[Int]] {
            buf += t.substring(with: NSRange(location: pos, length: m[0] - pos)) + "[" +
                t.substring(with: NSRange(location: m[0], length: m[1] - m[0])) + "]"
            pos = m[1]
        }
        buf += t.substring(from: pos)
        return ((s["pre"] as! Bool) ? "…" : "") + buf + ((s["post"] as! Bool) ? "…" : "")
    }

    func search(q: String, from: String?, to: String?, body: String?, limit: Int) throws -> [[String: Any]] {
        var sql = """
          SELECT p.id pid, p.page, p.dates, d.url, d.bodies, d.body_slugs, d.date_min dmin, d.date_max dmax,
                 d.pages npages, d.file
          FROM pages_fts JOIN pages p ON p.id = pages_fts.rowid JOIN docs d ON d.id = p.doc_id
          WHERE pages_fts MATCH ?
          """
        var args: [Any?] = [Index.ftsQuery(q)]
        if let body, !body.isEmpty { sql += " AND d.body_slugs LIKE ?"; args.append("%\"\(body)\"%") }
        sql += " ORDER BY bm25(pages_fts) LIMIT 20000"
        var rows: [[String: Any]]
        do { rows = try db.query(sql, args) } catch {
            let words = Index.terms(q).map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
            if words.isEmpty { return [] }
            args[0] = words.joined(separator: " ")
            rows = try db.query(sql, args)
        }
        let terms = Index.terms(q)
        let dated = from != nil || to != nil
        var hits: [[String: Any]] = []
        for r in rows {
            let pageDates = (try? JSONSerialization.jsonObject(with: Data((r["dates"] as? String ?? "[]").utf8))) as? [String] ?? []
            let dmin = r["dmin"] as? String, dmax = r["dmax"] as? String
            var datedBy: Any = NSNull()
            if dated {
                if !pageDates.isEmpty {
                    if !pageDates.contains(where: { (from == nil || $0 >= from!) && (to == nil || $0 <= to!) }) { continue }
                    datedBy = "page"
                } else if let lo = dmin ?? dmax, let hi = dmax ?? dmin {
                    if let from, hi < from { continue }
                    if let to, lo > to { continue }
                    datedBy = "document"
                } else {
                    continue // undatable pages are excluded when a date range is set
                }
            }
            let text = db.scalar("SELECT text FROM pages_fts WHERE rowid=?", [r["pid"]]) as? String ?? ""
            func arr(_ k: String) -> [String] {
                (try? JSONSerialization.jsonObject(with: Data((r[k] as? String ?? "[]").utf8))) as? [String] ?? []
            }
            hits.append([
                "url": r["url"] as? String ?? "", "page": r["page"] as? Int ?? 1, "npages": r["npages"] as? Int ?? 0,
                "file": r["file"] as? String ?? "",
                "bodies": arr("bodies"), "slugs": arr("body_slugs"),
                "page_dates": pageDates.isEmpty ? NSNull() : [pageDates.first!, pageDates.last!] as Any,
                "doc_dates": dmin == nil ? NSNull() : [dmin!, dmax ?? dmin!] as Any,
                "dated_by": datedBy,
                "snippets": Index.snippets(text, terms),
            ])
            if hits.count >= limit { break }
        }
        return hits
    }

    /// FOI requests from the dataset (what was asked, by whom, the decision), newest first.
    func searchRequests(q: String, from: String?, to: String?, body: String?, limit: Int) throws -> [[String: Any]] {
        var sql = """
          SELECT r.ref, r.body, r.slug, r.decision_date, r.date_received, r.requester_type, r.decision_status,
                 r.description, r.doc_url, r.date_iso, d.file, d.status dstatus
          FROM records_fts JOIN records r ON r.rid = records_fts.rowid LEFT JOIN docs d ON d.url = r.doc_url
          WHERE records_fts MATCH ?
          """
        var args: [Any?] = [Index.ftsQuery(q)]
        if let body, !body.isEmpty { sql += " AND r.slug = ?"; args.append(body) }
        // undated requests are excluded when a date range is set
        if let from { sql += " AND r.date_iso >= ?"; args.append(from) }
        if let to { sql += " AND r.date_iso <= ?"; args.append(to) }
        sql += " ORDER BY r.date_iso IS NULL, r.date_iso DESC, bm25(records_fts) LIMIT ?"
        args.append(limit)
        var rows: [[String: Any]]
        do { rows = try db.query(sql, args) } catch {
            let words = Index.terms(q).map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
            if words.isEmpty { return [] }
            args[0] = words.joined(separator: " ")
            rows = try db.query(sql, args)
        }
        let terms = Index.terms(q)
        return rows.map { r in
            func v(_ k: String) -> Any { r[k] ?? NSNull() }
            let desc = r["description"] as? String ?? ""
            return ["ref": v("ref"), "body": v("body"), "slug": v("slug"), "decision_date": v("decision_date"),
                    "date_received": v("date_received"), "requester_type": v("requester_type"),
                    "decision_status": v("decision_status"), "url": v("doc_url"), "date": v("date_iso"),
                    "file": (r["dstatus"] as? String) == "ok" ? v("file") : NSNull(),
                    "desc": Index.snippets(desc, terms, width: 1_000_000, maxN: 1)[0]]
        }
    }

    func requestsCSV(_ rows: [[String: Any]]) -> String {
        func esc(_ x: Any?) -> String { "\"" + ((x as? String) ?? "").replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["reference,body,decision_date,date_received,requester_type,decision_status,request,foi_request_file"]
        for r in rows {
            lines.append([esc(r["ref"]), esc(r["body"]), esc(r["decision_date"]), esc(r["date_received"]),
                          esc(r["requester_type"]), esc(r["decision_status"]),
                          esc((r["desc"] as? [String: Any])?["text"]), esc(r["url"])].joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// First page of an indexed PDF that mentions an FOI reference number.
    func pageForRef(url: String, ref: String) -> Int? {
        let clean = ref.replacingOccurrences(of: "\"", with: "")
        return db.scalar("""
            SELECT p.page FROM pages_fts JOIN pages p ON p.id = pages_fts.rowid JOIN docs d ON d.id = p.doc_id
            WHERE d.url = ? AND pages_fts MATCH ? ORDER BY p.page LIMIT 1
            """, [url, "\"\(clean)\""]) as? Int
    }

    func bodies() -> [[String: Any]] {
        ((try? db.query("SELECT slug, MAX(body) name, COUNT(*) n FROM records WHERE slug IS NOT NULL GROUP BY slug ORDER BY name COLLATE NOCASE")) ?? [])
    }

    func csv(_ hits: [[String: Any]]) -> String {
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["body,pdf_url,page,page_link,dates_on_page,document_record_dates,snippet"]
        for h in hits {
            let url = h["url"] as! String, page = h["page"] as! Int
            let pd = (h["page_dates"] as? [String])?.joined(separator: " to ") ?? ""
            let dd = (h["doc_dates"] as? [String])?.joined(separator: " to ") ?? ""
            let sn = (h["snippets"] as! [[String: Any]]).map(Index.snippetText).joined(separator: " | ")
            lines.append([esc((h["bodies"] as! [String]).joined(separator: "; ")), esc(url), "\(page)",
                          esc("\(url)#page=\(page)"), esc(pd), esc(dd), esc(sn)].joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

// MARK: - PDF viewer window

final class PDFWindowController: NSWindowController, NSWindowDelegate {
    static var open: [PDFWindowController] = []

    static func show(file: URL, page: Int, terms: [String], title: String, original: String) {
        guard let doc = PDFDocument(url: file) else {
            if let u = Fetcher.encode(original) { NSWorkspace.shared.open(u) }
            return
        }
        let view = PDFView()
        view.document = doc
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        var sels: [PDFSelection] = []
        for t in terms { sels += doc.findString(t, withOptions: [.caseInsensitive, .diacriticInsensitive]) }
        sels.forEach { $0.color = NSColor.systemYellow.withAlphaComponent(0.6) }
        view.highlightedSelections = sels
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 1000),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "\(title) — page \(page)"
        w.contentView = view
        w.setFrameAutosaveName("PDFViewer")
        w.center()
        let c = PDFWindowController(window: w)
        w.delegate = c
        open.append(c)
        c.showWindow(nil)
        if let p = doc.page(at: max(0, page - 1)) {
            DispatchQueue.main.async {
                view.go(to: p)
                if let first = sels.first(where: { $0.pages.contains(p) }) { view.go(to: first) }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        PDFWindowController.open.removeAll { $0 === self }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var index: Index!

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        do { index = try Index() } catch {
            let a = NSAlert(); a.messageText = "FOI Search could not open its index"; a.informativeText = "\(error)"
            a.runModal(); NSApp.terminate(nil); return
        }
        index.onProgress = { [weak self] in DispatchQueue.main.async { self?.pushStatus() } }

        let cfg = WKWebViewConfiguration()
        cfg.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "api")
        web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.loadHTMLString(pageHTML, baseURL: nil)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 820),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "FOI Search"
        window.contentView = web
        window.minSize = NSSize(width: 520, height: 400)
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // refresh automatically on first run and then at most once a day
        let last = index.meta("last_update").flatMap { ISO8601DateFormatter().date(from: $0) }
        if last == nil || Date().timeIntervalSince(last!) > 86400 { startUpdate() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    @objc func startUpdate() {
        let idx = index!
        Task.detached { await idx.update() }
    }

    @objc func showData() { NSWorkspace.shared.activateFileViewerSelecting([dataDir]) }

    func pushStatus() {
        guard let web else { return }
        let st = index.state
        let payload: [String: Any] = ["running": st.running, "done": st.done, "total": st.total, "msg": st.msg,
                                      "stats": index.statsLine(), "last_update": index.meta("last_update") ?? NSNull()]
        if let d = try? JSONSerialization.data(withJSONObject: payload), let s = String(data: d, encoding: .utf8) {
            web.evaluateJavaScript("window.onStatus && window.onStatus(\(s))")
        }
    }

    // JS → Swift bridge
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
            replyHandler(nil, "bad message"); return
        }
        let idx = index!
        func str(_ k: String) -> String? { (body[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch cmd {
        case "info":
            let st = idx.state
            replyHandler(["stats": idx.statsLine(), "bodies": idx.bodies(), "last_update": idx.meta("last_update") ?? NSNull(),
                          "running": st.running, "done": st.done, "total": st.total, "msg": st.msg], nil)
        case "search", "csv":
            let q = str("q") ?? "", from = str("from"), to = str("to"), bodyF = str("body")
            let isCSV = cmd == "csv", requests = str("kind") == "requests"
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let limit = isCSV ? 100_000 : (requests ? 1000 : 500)
                    let rows = requests
                        ? try idx.searchRequests(q: q, from: from, to: to, body: bodyF, limit: limit)
                        : try idx.search(q: q, from: from, to: to, body: bodyF, limit: limit)
                    if isCSV {
                        let text = requests ? idx.requestsCSV(rows) : idx.csv(rows)
                        let name = requests ? "FOI requests.csv" : "FOI responses.csv"
                        DispatchQueue.main.async { self.saveCSV(text, name: name); replyHandler(["ok": true], nil) }
                        return
                    }
                    let res: [String: Any] = ["hits": rows, "truncated": rows.count >= limit]
                    DispatchQueue.main.async { replyHandler(res, nil) }
                } catch {
                    DispatchQueue.main.async { replyHandler(["error": "Search failed: \(error)"], nil) }
                }
            }
        case "update":
            startUpdate(); replyHandler(["ok": true], nil)
        case "openPDF":
            let file = pdfDir.appendingPathComponent(str("file") ?? "")
            let url = str("url") ?? ""
            let name = (URL(string: url)?.lastPathComponent).flatMap { $0.removingPercentEncoding } ?? "PDF"
            var terms = Index.terms(str("q") ?? "")
            var page = body["page"] as? Int
            if let ref = str("ref") {
                terms.insert(ref, at: 0)
                if page == nil { page = idx.pageForRef(url: url, ref: ref) }
            }
            PDFWindowController.show(file: file, page: page ?? 1, terms: terms, title: name, original: url)
            replyHandler(["ok": true], nil)
        case "openURL":
            if let u = Fetcher.encode(str("url") ?? ""), ["http", "https"].contains(u.scheme ?? "") { NSWorkspace.shared.open(u) }
            replyHandler(["ok": true], nil)
        default:
            replyHandler(nil, "unknown command")
        }
    }

    func saveCSV(_ text: String, name: String) {
        let p = NSSavePanel()
        p.allowedContentTypes = [.commaSeparatedText]
        p.nameFieldStringValue = name
        p.beginSheetModal(for: window) { r in
            guard r == .OK, let url = p.url else { return }
            try? (Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)).write(to: url)
        }
    }

    // keep the app window on the app page; send any other link to the browser
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let u = action.request.url, u.scheme != "about" {
            NSWorkspace.shared.open(u); decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith c: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url { NSWorkspace.shared.open(u) }
        return nil
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "About FOI Search", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide FOI Search", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit FOI Search", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: "File")
        let upd = file.addItem(withTitle: "Check for New Disclosures", action: #selector(startUpdate), keyEquivalent: "r")
        upd.target = self
        let show = file.addItem(withTitle: "Show Downloaded PDFs in Finder", action: #selector(showData), keyEquivalent: "")
        show.target = self
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winItem.submenu = win
        NSApp.windowsMenu = win
        NSApp.mainMenu = main
    }
}

// MARK: - Page

let pageHTML = #"""
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FOI Search</title>
<style>
:root{--bg:#f6f6f4;--card:#fff;--fg:#1d1d1b;--mut:#6b6b66;--line:#e2e1dc;--acc:#0b6e4f;--mark:#ffe58a;--seg:#e8e7e2}
@media (prefers-color-scheme:dark){:root{--bg:#1c1c1e;--card:#2a2a2c;--fg:#ecebe6;--mut:#a09f99;--line:#3a3a3c;--acc:#4fc79a;--mark:#6b5a12;--seg:#323234}}
*{box-sizing:border-box}html,body{background:var(--bg)}body{margin:0;color:var(--fg);font:14px/1.5 -apple-system,system-ui,sans-serif;-webkit-user-select:text}
.wrap{max-width:980px;margin:0 auto;padding:22px 20px 60px}
.sub{color:var(--mut);margin:0 0 14px;font-size:13px}
form{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px;display:grid;gap:12px;grid-template-columns:1fr 1fr 1.4fr}
form .q{grid-column:1/-1}label{display:block;font-size:11px;color:var(--mut);margin-bottom:4px;font-weight:600;text-transform:uppercase;letter-spacing:.04em}
input,select{width:100%;padding:8px 10px;border:1px solid var(--line);border-radius:7px;background:var(--bg);color:var(--fg);font:inherit}
input:focus,select:focus{outline:2px solid var(--acc);outline-offset:-1px}
.q input{font-size:17px;padding:10px 12px}
.row{grid-column:1/-1;display:flex;gap:10px;align-items:center;flex-wrap:wrap}
button{background:var(--acc);color:#fff;border:0;border-radius:7px;padding:8px 18px;font:inherit;font-weight:600;cursor:pointer}
button.sec{background:transparent;color:var(--acc);border:1px solid var(--line)}
button:disabled{opacity:.55;cursor:default}
.hint{color:var(--mut);font-size:12px}
.tabs{display:flex;gap:2px;background:var(--seg);border-radius:9px;padding:3px;margin:18px 0 4px;width:max-content;max-width:100%}
.tab{background:transparent;color:var(--fg);font-weight:500;padding:6px 18px;border-radius:7px;font-size:13.5px}
.tab[aria-selected=true]{background:var(--card);box-shadow:0 1px 2px rgba(0,0,0,.12);font-weight:600}
.tab .n{color:var(--mut);font-weight:500;margin-left:4px;font-variant-numeric:tabular-nums}
.status{color:var(--mut);font-size:13px}
.stat{margin:10px 2px;min-height:20px}
.doc,.req{background:var(--card);border:1px solid var(--line);border-radius:10px;margin:8px 0}
details>summary{list-style:none;cursor:pointer;padding:11px 16px 11px 34px;position:relative;border-radius:10px}
details>summary::-webkit-details-marker{display:none}
details>summary::before{content:"";position:absolute;left:15px;top:17px;width:6px;height:6px;border-right:2px solid var(--mut);border-bottom:2px solid var(--mut);transform:rotate(-45deg);transition:transform .15s}
details[open]>summary::before{transform:rotate(45deg);top:15px}
details>summary:hover{background:var(--bg)}
details>summary:focus-visible{outline:2px solid var(--acc);outline-offset:-2px}
.inner{padding:2px 16px 12px 34px}
.doc .ttl{font-weight:600;font-size:14px;word-break:break-word}
.doc .cnt,.req .cnt{color:var(--mut);font-weight:500;font-size:12px;white-space:nowrap}
.sumrow{display:flex;gap:10px;align-items:baseline;justify-content:space-between}
.sumrow .l{min-width:0}
.req .date{font-weight:600;font-size:12.5px;font-variant-numeric:tabular-nums;white-space:nowrap;color:var(--mut);margin-right:10px}
.req .rtitle{word-break:break-word}
.req summary .meta{margin:2px 0 0}
.stat{display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap}
.tog{font-size:12px;display:flex;gap:12px}
a{color:var(--acc);cursor:pointer;text-decoration:none}a:hover{text-decoration:underline}
.meta{color:var(--mut);font-size:12px;margin:2px 0 8px}
.hit{border-top:1px solid var(--line);padding:8px 0 4px}.hit:first-of-type{border-top:0}
.pg{font-size:12.5px;font-weight:600}
.snip{font-size:13px;margin:4px 0;font-family:ui-monospace,Menlo,monospace;white-space:pre-wrap;word-break:break-word}
mark{background:var(--mark);color:inherit;padding:0 1px;border-radius:2px}
.req .top{display:flex;gap:8px;align-items:baseline;flex-wrap:wrap;font-size:12.5px}
.req .ref{font-weight:700;font-variant-numeric:tabular-nums}
.pill{font-size:11.5px;font-weight:600;padding:1px 8px;border-radius:10px;background:var(--seg)}
.pill.g{background:#d8f0e4;color:#0b5a3f}.pill.p{background:#fdf0d2;color:#7a5600}.pill.r{background:#f8dcdc;color:#8a2323}
@media (prefers-color-scheme:dark){.pill.g{background:#173d2e;color:#8fe0bb}.pill.p{background:#43361a;color:#f1cf7d}.pill.r{background:#4a2222;color:#f2a5a5}}
.req .desc{margin:6px 0 6px;white-space:pre-wrap;word-break:break-word}
.req .links{font-size:12.5px;display:flex;gap:14px;flex-wrap:wrap}
.bar{height:4px;background:var(--line);border-radius:2px;overflow:hidden;margin:6px 0 0;max-width:340px}.bar i{display:block;height:100%;background:var(--acc);width:0}
.foot{margin-top:28px;display:flex;gap:10px;align-items:center;flex-wrap:wrap}
.more{display:block;margin:14px auto}
.credit{margin-top:18px}
@media (max-width:700px){form{grid-template-columns:1fr}}
</style></head><body><div class="wrap">
<p class="sub">Search the FOI requests and the published response files (“FOI Request Files”) listed on publicinformation.ie.</p>
<form id="f">
  <div class="q"><label for="q">Search terms</label><input id="q" name="q" placeholder='e.g. "data protection" Meta  ·  tusla OR hiqa  ·  procure*' autofocus></div>
  <div><label for="from">From date</label><input id="from" name="from" type="date"></div>
  <div><label for="to">To date</label><input id="to" name="to" type="date"></div>
  <div><label for="body">Public body</label><select id="body" name="body"><option value="">All bodies</option></select></div>
  <div class="row"><button>Search</button><button class="sec" id="csv" type="button">Export CSV…</button>
  <span class="hint">Words are ANDed · "exact phrase" · OR · NOT · prefix* · NEAR(a b, 10). Dates are optional.</span></div>
</form>
<div class="tabs" role="tablist">
  <button class="tab" role="tab" id="t-responses" data-tab="responses" aria-selected="true">Responses<span class="n" id="n-responses"></span></button>
  <button class="tab" role="tab" id="t-requests" data-tab="requests" aria-selected="false">Requests<span class="n" id="n-requests"></span></button>
</div>
<section id="p-responses" role="tabpanel" aria-labelledby="t-responses"><div class="stat"><div class="status" id="s-responses"></div><div class="tog" id="g-responses" hidden><a data-all="responses" data-open-all="1">Expand all</a><a data-all="responses">Collapse all</a></div></div><div id="o-responses"></div></section>
<section id="p-requests" role="tabpanel" aria-labelledby="t-requests" hidden><div class="stat"><div class="status" id="s-requests"></div><div class="tog" id="g-requests" hidden><a data-all="requests" data-open-all="1">Expand all</a><a data-all="requests">Collapse all</a></div></div><div id="o-requests"></div></section>
<div class="foot hint"><span id="idx">Loading…</span><button class="sec" id="upd" type="button" style="padding:3px 10px;font-size:12px">Check for new disclosures</button></div>
<div class="bar" id="bar" hidden><i></i></div>
<p class="hint credit">FOI Search by Johnny Ryan · free and open source (MIT License): use, copy, change and share it freely.</p>
</div>
<script>
const $=s=>document.querySelector(s), esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const api=(cmd,args={})=>window.webkit.messageHandlers.api.postMessage({cmd,...args});
function mark(s){let t=s.text,o='',p=0;for(const[a,b]of s.marks){o+=esc(t.slice(p,a))+'<mark>'+esc(t.slice(a,b))+'</mark>';p=b}return(s.pre?'…':'')+o+esc(t.slice(p))+(s.post?'…':'')}
function markCut(s,n){const t=s.text;if(t.length<=n)return mark({...s,pre:false,post:false});let cut=t.lastIndexOf(' ',n);if(cut<n*0.6)cut=n;
  return mark({text:t.slice(0,cut),pre:false,post:true,marks:s.marks.filter(m=>m[1]<=cut)})}
function fmt(d){if(!d)return'';const x=new Date(d+'T00:00');return isNaN(x)?d:x.toLocaleDateString('en-IE',{day:'numeric',month:'short',year:'numeric'})}
function span(a){return a?(a[0]===a[1]?fmt(a[0]):fmt(a[0])+' – '+fmt(a[1])):''}
function params(){const o={};for(const[k,v]of new FormData($('#f')))if(v)o[k]=v;return o}
function when(iso){if(!iso)return'';const d=new Date(iso);return d.toLocaleString('en-IE',{day:'numeric',month:'short',hour:'2-digit',minute:'2-digit'})}
const fname=u=>{try{return decodeURIComponent(u.split('/').pop().split('?')[0])}catch(e){return u}};
let tab='responses',last={},data={responses:null,requests:null},shown={requests:100};
try{tab=localStorage.getItem('tab')||'responses'}catch(e){}
function setTab(t){tab=t;try{localStorage.setItem('tab',t)}catch(e){}
  for(const k of['responses','requests']){$('#t-'+k).setAttribute('aria-selected',k===t);$('#p-'+k).hidden=k!==t}}
document.querySelectorAll('.tab').forEach(b=>b.onclick=()=>setTab(b.dataset.tab));
window.onStatus=s=>{
  $('#idx').textContent=s.stats+(s.last_update?' · updated '+when(s.last_update):'')+(s.msg&&!s.running&&s.msg!=='Up to date.'?' · '+s.msg:'');
  const u=$('#upd');u.disabled=s.running;
  u.textContent=s.running?(s.total?`Updating… ${s.done}/${s.total}`:'Fetching dataset…'):'Check for new disclosures';
  $('#bar').hidden=!s.running;$('#bar i').style.width=s.total?(100*s.done/s.total)+'%':'4%';
  if(!s.running&&window._wasRunning)loadBodies();window._wasRunning=s.running;
};
async function loadBodies(){const r=await api('info');const sel=$('#body'),cur=sel.value;sel.length=1;
  for(const b of r.bodies){const o=document.createElement('option');o.value=b.slug;o.textContent=`${b.name} (${b.n.toLocaleString()} requests)`;sel.append(o)}sel.value=cur;window.onStatus(r)}

function renderResponses(r){
  const g=new Map();for(const h of r.hits){if(!g.has(h.url))g.set(h.url,{...h,hits:[]});g.get(h.url).hits.push(h)}
  $('#n-responses').textContent=r.hits.length?` ${r.hits.length}${r.truncated?'+':''}`:' 0';
  $('#s-responses').textContent=r.hits.length?`${r.hits.length}${r.truncated?'+':''} matching pages in ${g.size} PDFs`:'No matching pages in the response files.';
  $('#g-responses').hidden=g.size<1;
  let o='';for(const d of g.values()){const n=d.hits.length;
   o+=`<details class="doc"><summary><div class="sumrow"><div class="l"><div class="ttl">${esc(fname(d.url))}</div><div class="meta" style="margin:2px 0 0">${esc(d.bodies.join(', '))}${d.doc_dates?' · requests dated '+span(d.doc_dates):''}</div></div><span class="cnt">${n} matching page${n===1?'':'s'}</span></div></summary><div class="inner">
   <div class="meta"><a data-open="${esc(d.url)}" data-file="${esc(d.file)}" data-page="${d.hits[0].page}">Open PDF</a> · ${d.npages} pages · <a data-web="${esc(d.url)}">original on the web ↗</a></div>`;
   for(const h of d.hits){o+=`<div class="hit"><div class="pg"><a data-open="${esc(h.url)}" data-file="${esc(h.file)}" data-page="${h.page}">Page ${h.page}</a>${h.page_dates?` <span class="meta">· dates on page: ${span(h.page_dates)}</span>`:''}</div>`+h.snippets.map(s=>`<div class="snip">${mark(s)}</div>`).join('')+'</div>'}
   o+='</div></details>'}
  $('#o-responses').innerHTML=o}

function pill(st){if(!st)return'';const s=st.toLowerCase();const c=/part/.test(s)?'p':/refus|withdraw|no record/.test(s)?'r':/grant|releas/.test(s)?'g':'';return`<span class="pill ${c}">${esc(st)}</span>`}
function renderRequests(r){
  const hits=r.hits;$('#n-requests').textContent=` ${hits.length}${r.truncated?'+':''}`;
  $('#s-requests').textContent=hits.length?`${hits.length.toLocaleString()}${r.truncated?'+':''} matching requests, newest first`:'No matching requests.';
  $('#g-requests').hidden=hits.length<1;
  let o='';for(const h of hits.slice(0,shown.requests)){
   const main=h.date?fmt(h.date):(h.decision_date||h.date_received||'Undated');
   const dates=[h.decision_date?'Decided '+fmt(h.decision_date):'',h.date_received?'Received '+fmt(h.date_received):''].filter(Boolean).join(' · ');
   o+=`<details class="req"><summary><div class="sumrow"><div class="l"><span class="date">${esc(main)}</span><span class="rtitle">${markCut(h.desc,150)}</span><div class="meta">${esc(h.body)}</div></div><span class="cnt">${pill(h.decision_status)}</span></div></summary><div class="inner">
   <div class="top"><span class="ref">${esc(h.ref||'No reference')}</span>${h.requester_type?`<span class="pill">${esc(h.requester_type)}</span>`:''}<span class="meta" style="margin:0">${esc(dates)}</span></div>
   <div class="desc">${mark(h.desc)}</div>
   <div class="links">${h.url?(h.file?`<a data-open="${esc(h.url)}" data-file="${esc(h.file)}" data-ref="${esc(h.ref||'')}">FOI Request File: ${esc(fname(h.url))}</a>`:`<span class="hint">FOI Request File: ${esc(fname(h.url))}</span>`)+` <a data-web="${esc(h.url)}">web ↗</a>`:''}</div></div></details>`}
  if(hits.length>shown.requests)o+=`<button class="sec more" id="more">Show more (${(hits.length-shown.requests).toLocaleString()} left)</button>`;
  $('#o-requests').innerHTML=o;const m=$('#more');if(m)m.onclick=()=>{shown.requests+=200;renderRequests(r)}}

async function run(){const p=params();last=p;
  if(!p.q){for(const k of['responses','requests']){$('#o-'+k).innerHTML='';$('#s-'+k).textContent='';$('#n-'+k).textContent='';$('#g-'+k).hidden=true}return}
  if(p.from&&p.to&&p.from>p.to){$('#s-'+tab).textContent='The “from” date is after the “to” date.';return}
  shown.requests=100;
  for(const k of['responses','requests']){$('#s-'+k).textContent='Searching…';$('#n-'+k).textContent=' …'}
  const go=async k=>{const r=await api('search',{...p,kind:k});if(r.error){$('#s-'+k).textContent=r.error;$('#n-'+k).textContent='';return}
    data[k]=r;(k==='responses'?renderResponses:renderRequests)(r)};
  await Promise.all([go('responses'),go('requests')])}
document.addEventListener('click',e=>{const a=e.target.closest('a');if(!a)return;e.preventDefault();
  if(a.dataset.all){$('#o-'+a.dataset.all).querySelectorAll('details').forEach(d=>d.open=!!a.dataset.openAll);return}
  if(a.dataset.open){const args={url:a.dataset.open,file:a.dataset.file,q:last.q||''};if(a.dataset.page)args.page=+a.dataset.page;if(a.dataset.ref)args.ref=a.dataset.ref;api('openPDF',args)}
  else if(a.dataset.web)api('openURL',{url:a.dataset.web})});
$('#f').onsubmit=e=>{e.preventDefault();run()};
$('#csv').onclick=()=>{const p=params();if(!p.q){$('#s-'+tab).textContent='Enter search terms first.';return}api('csv',{...p,kind:tab})};
$('#upd').onclick=()=>api('update');
setTab(tab);loadBodies();
</script></body></html>
"""#

// MARK: - main

// Command-line search, for scripting: "FOI Search" --search "terms" [--requests] [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--body slug]
let cli = CommandLine.arguments
if let i = cli.firstIndex(of: "--search"), i + 1 < cli.count {
    func opt(_ k: String) -> String? { cli.firstIndex(of: k).flatMap { $0 + 1 < cli.count ? cli[$0 + 1] : nil } }
    let idx = try Index()
    if cli.contains("--requests") {
        let rows = try idx.searchRequests(q: cli[i + 1], from: opt("--from"), to: opt("--to"), body: opt("--body"), limit: 100_000)
        print(idx.requestsCSV(rows), terminator: "")
    } else {
        let hits = try idx.search(q: cli[i + 1], from: opt("--from"), to: opt("--to"), body: opt("--body"), limit: 100_000)
        print(idx.csv(hits), terminator: "")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
