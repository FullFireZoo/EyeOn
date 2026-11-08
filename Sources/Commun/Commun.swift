// EyeOn — code partagé par l'app, le hook (eyeon-hook) et l'outil de barres (eyeon-progres).
// Tout reste en local : les données vivent dans ~/Library/Application Support/EyeOn/.
import Foundation

enum EyeOn {
    /// Dossier de données. La variable d'environnement EYEON_DATA permet de le rediriger (tests).
    static var dossier: String {
        if let d = ProcessInfo.processInfo.environment["EYEON_DATA"], !d.isEmpty { return d }
        return vraiHome() + "/Library/Application Support/EyeOn"
    }
    static func chemin(_ nom: String) -> String { dossier + "/" + nom }
    static var dossierTaches: String { chemin("taches") }

    /// Le vrai dossier personnel, même depuis un processus sandboxé (le widget).
    static func vraiHome() -> String {
        if let pw = getpwuid(getuid()), let d = pw.pointee.pw_dir { return String(cString: d) }
        return NSHomeDirectory()
    }
    static func creerDossier(_ d: String = dossier) {
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    }
    static var maintenant: Double { Date().timeIntervalSince1970 }
}

// ——— Lecture / écriture JSON tolérantes (ne lèvent jamais) ———
func lireJSON(_ chemin: String) -> Any? {
    guard let data = FileManager.default.contents(atPath: chemin), !data.isEmpty else { return nil }
    return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}
func lireDico(_ chemin: String) -> [String: Any]? { lireJSON(chemin) as? [String: Any] }

/// Écriture atomique (fichier temporaire puis renommage).
@discardableResult
func ecrireJSON(_ objet: Any, _ chemin: String, joli: Bool = false) -> Bool {
    guard JSONSerialization.isValidJSONObject(objet) else { return false }
    let data: Data
    if joli { data = Data((jsonLisible(objet) + "\n").utf8) }
    else { guard let d = try? JSONSerialization.data(withJSONObject: objet, options: [.withoutEscapingSlashes]) else { return false }; data = d }
    let tmp = chemin + ".tmp-\(getpid())"
    // on garde les permissions du fichier existant (ex. settings.json en 600)
    let attrs = (try? FileManager.default.attributesOfItem(atPath: chemin)).flatMap { a in a[.posixPermissions].map { [FileAttributeKey.posixPermissions: $0] } }
    guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: attrs) else { return false }
    return rename(tmp, chemin) == 0
}

/// JSON lisible et fidèle pour les fichiers de réglages : clés triées, indentation de 2 espaces,
/// nombres écrits au plus court (0.1 reste 0.1), booléens et entiers préservés.
func jsonLisible(_ v: Any, _ niveau: Int = 0) -> String {
    let ind = String(repeating: "  ", count: niveau + 1), fin = String(repeating: "  ", count: niveau)
    switch v {
    case let d as [String: Any]:
        if d.isEmpty { return "{}" }
        return "{\n" + d.keys.sorted().map { ind + chaineJSON($0) + ": " + jsonLisible(d[$0]!, niveau + 1) }.joined(separator: ",\n") + "\n" + fin + "}"
    case let a as [Any]:
        if a.isEmpty { return "[]" }
        return "[\n" + a.map { ind + jsonLisible($0, niveau + 1) }.joined(separator: ",\n") + "\n" + fin + "]"
    case let s as String: return chaineJSON(s)
    case let n as NSNumber:
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
        let t = String(cString: n.objCType)
        if ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(t) { return n.stringValue }
        let d = n.doubleValue
        if d.isFinite && d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
        return d.isFinite ? "\(d)" : "null"
    default: return "null"
    }
}
func chaineJSON(_ s: String) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return "\"\"" }
    return String(decoding: d, as: UTF8.self)
}

/// Verrou exclusif sur un fichier (flock) le temps d'exécuter le bloc.
func avecVerrou<T>(_ chemin: String, _ bloc: () -> T) -> T {
    let fd = open(chemin, O_CREAT | O_RDWR, 0o644)
    if fd >= 0 { flock(fd, LOCK_EX) }
    defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
    return bloc()
}

func nombre(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
}

func jourLocal(_ t: Double = EyeOn.maintenant) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
    return f.string(from: Date(timeIntervalSince1970: t))
}

// ——— Barres de progression (taches/<id>.json) ———
enum Progres {
    static func nettoyerId(_ id: String) -> String {
        let ok = id.map { c -> Character in (c.isLetter || c.isNumber || c == "-" || c == "_" || c == ".") ? c : "-" }
        let s = String(ok).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return s.isEmpty ? "tache" : String(s.prefix(80))
    }

    static func maj(id: String, titre: String, fait: Double, total: Double, detail: String = "") {
        EyeOn.creerDossier(EyeOn.dossierTaches)
        let p = EyeOn.dossierTaches + "/" + nettoyerId(id) + ".json"
        let ancien = lireDico(p)
        let now = EyeOn.maintenant
        var d: [String: Any] = ["titre": titre, "fait": fait, "total": total, "detail": detail,
                                "debut": nombre(ancien?["debut"]) ?? now, "maj": now]
        if total > 0 && fait >= total {
            if let deja = nombre(ancien?["fin"]) { d["fin"] = deja } else { d["fin"] = now; noterFin(titre) }
        }
        ecrireJSON(d, p)
    }

    @discardableResult
    static func fin(id: String) -> Bool {
        let p = EyeOn.dossierTaches + "/" + nettoyerId(id) + ".json"
        guard var d = lireDico(p) else { return false }
        if d["fin"] == nil { noterFin(d["titre"] as? String ?? id); d["fin"] = EyeOn.maintenant }
        if let t = d["total"] { d["fait"] = t }
        return ecrireJSON(d, p)
    }

    /// Journal des tâches terminées (résumé de la journée).
    static func noterFin(_ titre: String) {
        EyeOn.creerDossier()
        guard let data = try? JSONSerialization.data(withJSONObject: ["t": EyeOn.maintenant, "titre": titre], options: [.withoutEscapingSlashes]) else { return }
        let p = EyeOn.chemin("termines.jsonl")
        if !FileManager.default.fileExists(atPath: p) { FileManager.default.createFile(atPath: p, contents: nil) }
        guard let h = FileHandle(forWritingAtPath: p) else { return }
        h.seekToEndOfFile(); h.write(data + Data("\n".utf8)); try? h.close()
    }
}

// ——— Connexion à Claude Code : fusion / retrait des hooks dans ~/.claude/settings.json ———
enum ConnexionClaude {
    static let evenements = ["UserPromptSubmit", "PreToolUse", "SubagentStart", "SubagentStop", "Stop",
                             "SessionEnd", "PreCompact", "TaskCreated", "TaskCompleted"]
    /// Marqueur qui identifie nos hooks (le nom du binaire embarqué).
    static let marqueur = "eyeon-hook"

    static var fichierParDefaut: String {
        if let f = ProcessInfo.processInfo.environment["EYEON_CLAUDE_SETTINGS"], !f.isEmpty { return f }
        return EyeOn.vraiHome() + "/.claude/settings.json"
    }

    enum Erreur: LocalizedError {
        case illisible(String)
        var errorDescription: String? {
            switch self { case .illisible(let f): return "Le fichier \(f) n'est pas un JSON valide : rien n'a été modifié." }
        }
    }

    static func commande(pour binaire: String) -> String { "\"\(binaire)\"" }

    static func estANous(_ h: Any) -> Bool {
        ((h as? [String: Any])?["command"] as? String)?.contains(marqueur) == true
    }

    static func lire(_ fichier: String) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: fichier) else { return nil }
        let data = FileManager.default.contents(atPath: fichier) ?? Data()
        if data.isEmpty || String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Erreur.illisible(fichier) }
        return d
    }

    /// Commande actuellement enregistrée pour nos hooks (nil si non connecté).
    static func commandeInstallee(_ fichier: String = fichierParDefaut) -> String? {
        guard let d = try? lire(fichier), let hooks = d["hooks"] as? [String: Any] else { return nil }
        for ev in evenements {
            for g in hooks[ev] as? [[String: Any]] ?? [] {
                for h in g["hooks"] as? [Any] ?? [] where estANous(h) { return (h as? [String: Any])?["command"] as? String }
            }
        }
        return nil
    }
    static func estConnecte(_ fichier: String = fichierParDefaut) -> Bool { commandeInstallee(fichier) != nil }

    /// Retire nos hooks d'un dictionnaire « hooks » (les autres hooks restent intacts).
    static func retirer(_ hooks: [String: Any]) -> [String: Any] {
        var res = hooks
        for (ev, valeur) in hooks {
            guard let groupes = valeur as? [Any] else { continue }
            var gardes: [Any] = []
            for g in groupes {
                guard var gd = g as? [String: Any], let hs = gd["hooks"] as? [Any] else { gardes.append(g); continue }
                let restant = hs.filter { !estANous($0) }
                if restant.count == hs.count { gardes.append(g); continue }
                if !restant.isEmpty { gd["hooks"] = restant; gardes.append(gd) }
            }
            if gardes.isEmpty { res.removeValue(forKey: ev) } else { res[ev] = gardes }
        }
        return res
    }

    static func sauvegarder(_ fichier: String) -> String? {
        guard FileManager.default.fileExists(atPath: fichier) else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        var dest = fichier + ".eyeon-sauvegarde-" + f.string(from: Date())
        var n = 2
        while FileManager.default.fileExists(atPath: dest) { dest = fichier + ".eyeon-sauvegarde-" + f.string(from: Date()) + "-\(n)"; n += 1 }
        return (try? FileManager.default.copyItem(atPath: fichier, toPath: dest)) != nil ? dest : nil
    }

    /// Ajoute (ou met à jour) nos hooks. Idempotent. Renvoie le chemin de la sauvegarde.
    @discardableResult
    static func connecter(binaire: String, fichier: String = fichierParDefaut) throws -> String? {
        var d = try lire(fichier) ?? [:]
        var hooks = retirer(d["hooks"] as? [String: Any] ?? [:])
        let h: [String: Any] = ["type": "command", "command": commande(pour: binaire), "async": true, "timeout": 5]
        for ev in evenements {
            var groupe: [String: Any] = ["hooks": [h]]
            if ev == "PreToolUse" { groupe["matcher"] = "*" }
            hooks[ev] = (hooks[ev] as? [Any] ?? []) + [groupe]
        }
        d["hooks"] = hooks
        let sauvegarde = sauvegarder(fichier)
        try FileManager.default.createDirectory(atPath: (fichier as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard ecrireJSON(d, fichier, joli: true) else { throw Erreur.illisible(fichier) }
        return sauvegarde
    }

    /// Retire proprement nos hooks (et rien d'autre). Renvoie le chemin de la sauvegarde.
    @discardableResult
    static func deconnecter(fichier: String = fichierParDefaut) throws -> String? {
        guard var d = try lire(fichier), let hooks = d["hooks"] as? [String: Any] else { return nil }
        guard estConnecte(fichier) else { return nil }
        let reste = retirer(hooks)
        if reste.isEmpty { d.removeValue(forKey: "hooks") } else { d["hooks"] = reste }
        let sauvegarde = sauvegarder(fichier)
        guard ecrireJSON(d, fichier, joli: true) else { throw Erreur.illisible(fichier) }
        return sauvegarde
    }
}
