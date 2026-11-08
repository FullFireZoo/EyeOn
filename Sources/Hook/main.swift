// eyeon-hook — appelé par les hooks de Claude Code (stdin = JSON de l'événement).
// Met à jour ~/Library/Application Support/EyeOn/etat.json. Rapide, ne plante jamais, sort toujours avec le code 0.
import Foundation

func court(_ v: Any?, _ n: Int = 70) -> String {
    let s = ((v as? String) ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return s.count <= n ? s : String(s.prefix(n - 1)) + "…"
}
func texte(_ v: Any?) -> String { (v as? String) ?? "" }
func nomFichier(_ v: Any?) -> String {
    let s = texte(v); var t = s
    while t.hasSuffix("/") { t.removeLast() }
    let n = (t as NSString).lastPathComponent
    return n.isEmpty ? s : n
}

func action(_ outil: String, _ e: [String: Any]) -> String {
    let i = e["tool_input"] as? [String: Any] ?? [:]
    switch outil {
    case "Bash": return texte(i["description"]).isEmpty ? "Commande terminal" : texte(i["description"])
    case "Read": return "Lecture de \(nomFichier(i["file_path"]))"
    case "Write", "Edit", "NotebookEdit": return "Écriture de \(nomFichier(i["file_path"] ?? i["notebook_path"]))"
    case "Grep", "Glob": return "Recherche dans les fichiers"
    case "Agent", "Task": return "Lance un agent : \(texte(i["description"]))"
    case "WebSearch": return "Recherche web : \(texte(i["query"]))"
    case "WebFetch": return "Lecture d’une page web"
    case "Monitor": return texte(i["description"]).isEmpty ? "Surveillance" : texte(i["description"])
    case "Skill": return "Compétence : \(texte(i["skill"]))"
    case "AskUserQuestion": return "Te pose une question"
    case "TodoWrite": return "Planifie les étapes"
    default:
        if outil.hasPrefix("mcp__claude-in-chrome") { return "Navigation dans Chrome" }
        return outil.replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "__", with: " · ")
    }
}

/// Barre automatique « Étapes de la demande » dès que Claude a au moins 2 étapes prévues.
func etapes(_ sid: String, _ s: [String: Any]) {
    let tot = nombre(s["etapes_total"]) ?? 0
    let fait = min(nombre(s["etapes_faites"]) ?? 0, tot)
    guard tot >= 2 else { return }
    // le nom du projet distingue les sessions parallèles (chaque anneau du widget est identifié par son titre)
    let projet = texte(s["projet"])
    let titre = projet.isEmpty ? "Étapes de la demande" : "Étapes · \(projet)"
    Progres.maj(id: "etapes-" + sid, titre: titre, fait: fait, total: tot, detail: texte(s["action"]))
}

func traiter(_ e: [String: Any]) {
    let ev = texte(e["hook_event_name"])
    let sid = String((texte(e["session_id"]).isEmpty ? "?" : texte(e["session_id"])).prefix(8))
    let now = EyeOn.maintenant
    EyeOn.creerDossier()
    let fichier = EyeOn.chemin("etat.json")
    avecVerrou(EyeOn.chemin(".verrou")) {
        var et = lireDico(fichier) ?? [:]
        var S = et["sessions"] as? [String: [String: Any]] ?? [:]
        var A = et["agents"] as? [String: [String: Any]] ?? [:]
        var s = S[sid] ?? ["debut": now, "projet": nomFichier(e["cwd"])]
        s["maj"] = now
        if let tp = e["transcript_path"] as? String, !tp.isEmpty { s["transcript"] = tp }
        if let m = e["model"] as? String { s["modele"] = m }
        var J = et["journee"] as? [String: Any] ?? [:]
        let jour = jourLocal(now)
        if texte(J["date"]) != jour { J = ["date": jour, "secondes": 0, "demandes": 0] }

        switch ev {
        case "UserPromptSubmit":
            s["statut"] = "travaille"; s["demande"] = court(e["prompt"], 90); s["action"] = "Lit ta demande"
            s["depuis"] = now; s["question"] = false; s["etapes_total"] = 0; s["etapes_faites"] = 0
            s.removeValue(forKey: "attend_depuis")
            // Le terminal qui héberge Claude Code (pour le bouton « Terminal » et la priorité des alertes)
            if let t = ProcessInfo.processInfo.environment["__CFBundleIdentifier"], !t.isEmpty { et["terminal"] = t }
            J["demandes"] = (nombre(J["demandes"]) ?? 0) + 1
        case "PreToolUse":
            let outil = texte(e["tool_name"])
            let a = court(action(outil, e))
            s["statut"] = "travaille"; s["action"] = a
            var h = s["historique"] as? [[String: Any]] ?? []
            h.append(["t": now, "a": a]); if h.count > 10 { h.removeFirst(h.count - 10) }
            s["historique"] = h
            let ti = e["tool_input"] as? [String: Any] ?? [:]
            if ["Write", "Edit", "NotebookEdit"].contains(outil), let f = (ti["file_path"] ?? ti["notebook_path"]) as? String, !f.isEmpty { et["dernier_fichier"] = f }
            if outil == "AskUserQuestion" { s["question"] = true }
            if outil == "TodoWrite", let todos = ti["todos"] as? [[String: Any]], !todos.isEmpty {
                s["etapes_total"] = todos.count
                s["etapes_faites"] = todos.filter { texte($0["status"]) == "completed" }.count
                etapes(sid, s)
            }
            if outil == "Agent" || outil == "Task" { et["agent_attente"] = court(ti["description"], 50) }
        case "SubagentStart":
            let aid = texte(e["agent_id"]).isEmpty ? "\(now)" : texte(e["agent_id"])
            let attente = texte(et.removeValue(forKey: "agent_attente"))
            let desc = !attente.isEmpty ? attente : (!texte(e["agent_type"]).isEmpty ? texte(e["agent_type"]) : "Agent")
            A[aid] = ["session": sid, "desc": desc, "debut": now, "statut": "en cours"]
        case "SubagentStop":
            let aid = texte(e["agent_id"])
            if var a = A[aid] { a["statut"] = "terminé"; a["fin"] = now; A[aid] = a }
        case "Stop":
            if texte(s["statut"]) == "travaille", let dep = nombre(s["depuis"]) {
                J["secondes"] = (nombre(J["secondes"]) ?? 0) + max(0, now - dep)
            }
            s["statut"] = "attend"; s["action"] = "Attend ta réponse"; s["attend_depuis"] = now
        case "TaskCreated", "TaskCompleted":
            let k = ev == "TaskCreated" ? "etapes_total" : "etapes_faites"
            s[k] = (nombre(s[k]) ?? 0) + 1
            etapes(sid, s)
        case "PreCompact":
            var c = (et["compressions"] as? [Any] ?? []).compactMap { nombre($0) }
            c.append(now); if c.count > 20 { c.removeFirst(c.count - 20) }
            et["compressions"] = c
            s["action"] = "Compresse sa mémoire"
        default: break
        }

        if ev == "SessionEnd" { S.removeValue(forKey: sid) } else { S[sid] = s }
        // Ménage : sessions inactives depuis plus de 2 h, agents terminés depuis plus de 10 min (ou lancés il y a plus de 4 h)
        S = S.filter { now - (nombre($0.value["maj"]) ?? 0) <= 7200 }
        A = A.filter { _, a in
            if let f = nombre(a["fin"]), now - f > 600 { return false }
            return now - (nombre(a["debut"]) ?? now) <= 14400
        }
        et["sessions"] = S; et["agents"] = A; et["journee"] = J
        ecrireJSON(et, fichier)
    }
}

// Point d'entrée : on lit stdin, on traite, on ne fait jamais échouer Claude Code.
signal(SIGPIPE, SIG_IGN)
let entree = FileHandle.standardInput.readDataToEndOfFile()
if let e = try? JSONSerialization.jsonObject(with: entree) as? [String: Any] { traiter(e) }
exit(0)
