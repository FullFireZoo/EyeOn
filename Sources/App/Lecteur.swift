// Fusionne l'état des sessions, les barres de progression, la mémoire (contexte) de Claude,
// la Concentration du Mac et le résumé de la journée → un seul dictionnaire pour le panneau et le widget.
import Foundation

enum Lecteur {
    static func lire() -> [String: Any] {
        let now = EyeOn.maintenant
        let fm = FileManager.default
        var et = lireDico(EyeOn.chemin("etat.json")) ?? [:]
        let vus = lireDico(EyeOn.chemin("vus.json")) ?? [:]

        // Barres de progression
        var taches: [[String: Any]] = []
        let dossierT = EyeOn.dossierTaches
        for f in (try? fm.contentsOfDirectory(atPath: dossierT)) ?? [] where f.hasSuffix(".json") {
            let p = dossierT + "/" + f
            guard var t = lireDico(p) else { continue }
            // Tâche finie : son anneau vert reste jusqu'à ce que tu aies vu la fin (+20 s), 15 min au plus
            if let fin = nombre(t["fin"]) {
                let cle = "\(t["titre"] as? String ?? "")|\(cleNombre(t["debut"]))"
                if let vu = nombre(vus[cle]), now - vu > 20 { try? fm.removeItem(atPath: p); continue }
                if now - fin > 900 { try? fm.removeItem(atPath: p); continue }
            } else if now - (nombre(t["maj"]) ?? now) > 600 { t["bloque"] = true }
            taches.append(t)
        }
        taches.sort { a, b in
            let fa = a["fin"] != nil, fb = b["fin"] != nil
            if fa != fb { return !fa }
            return (nombre(a["debut"]) ?? 0) > (nombre(b["debut"]) ?? 0)
        }

        let jour = jourLocal(now)
        let J0 = et["journee"] as? [String: Any] ?? [:]
        let J = (J0["date"] as? String) == jour ? J0 : [:]
        var fins: [String] = []
        if let brut = try? String(contentsOfFile: EyeOn.chemin("termines.jsonl"), encoding: .utf8) {
            for ligne in brut.split(separator: "\n") {
                guard let x = try? JSONSerialization.jsonObject(with: Data(ligne.utf8)) as? [String: Any],
                      let t = nombre(x["t"]), jourLocal(t) == jour else { continue }
                fins.append(x["titre"] as? String ?? "")
            }
        }

        // Simulation de veille (pour tester l'affichage) : simulation-veille.json {"jusqu": horodatage}
        let sim = EyeOn.chemin("simulation-veille.json")
        if let s = lireDico(sim) {
            if now < (nombre(s["jusqu"]) ?? 0) {
                var S = et["sessions"] as? [String: [String: Any]] ?? [:]
                for k in S.keys { S[k]?["statut"] = "attend"; S[k]?["maj"] = now - 3600; S[k]?["action"] = "" }
                et["sessions"] = S; et["agents"] = [String: Any](); taches = []
            } else { try? fm.removeItem(atPath: sim) }
        }

        let sessions = et["sessions"] as? [String: [String: Any]] ?? [:]
        // Temps de travail de la journée, avec la demande en cours comptée en direct
        var sec = nombre(J["secondes"]) ?? 0
        for s in sessions.values where (s["statut"] as? String) == "travaille" {
            if let dep = nombre(s["depuis"]), now - (nombre(s["maj"]) ?? 0) < 300 { sec += max(0, now - dep) }
        }

        let journee: [String: Any] = ["secondes": Int(sec.rounded()), "demandes": Int(nombre(J["demandes"]) ?? 0),
                                      "taches": Array(fins.suffix(8)), "nb_taches": fins.count]
        var res: [String: Any] = [
            "concentration": concentration(), "now": now, "sessions": sessions,
            "agents": et["agents"] as? [String: Any] ?? [:], "taches": taches, "journee": journee,
        ]
        if let m = memoire(sessions, compressions: (et["compressions"] as? [Any] ?? []).compactMap { nombre($0) }, jour: jour) { res["memoire"] = m }
        if let f = et["dernier_fichier"] as? String { res["dernier_fichier"] = f }
        if let t = et["terminal"] as? String { res["terminal"] = t }
        return res
    }

    /// Clé stable d'un nombre (même texte que celui utilisé pour marquer « vu »).
    static func cleNombre(_ v: Any?) -> String {
        guard let d = nombre(v) else { return "" }
        return String(format: "%.3f", d)
    }

    // ——— Concentration / Ne pas déranger du Mac (lisible seulement avec l'Accès complet au disque) ———
    static func concentration() -> [String: Any] {
        let base = EyeOn.vraiHome() + "/Library/DoNotDisturb/DB/"
        let fichier = base + "Assertions.json"
        var c: [String: Any] = ["actif": false, "nom": "", "lisible": FileManager.default.isReadableFile(atPath: fichier)]
        guard let d = lireDico(fichier), let data = (d["data"] as? [[String: Any]])?.first,
              let recs = data["storeAssertionRecords"] as? [[String: Any]], let dernier = recs.last else { return c }
        let mid = (dernier["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"] as? String ?? ""
        var nom = ""
        if let m = lireDico(base + "ModeConfigurations.json"), let mc = ((m["data"] as? [[String: Any]])?.first)?["modeConfigurations"] as? [String: Any],
           let mode = (mc[mid] as? [String: Any])?["mode"] as? [String: Any] {
            nom = mode["name"] as? String ?? ""
        }
        c = ["lisible": true, "actif": true, "nom": nom == "Do Not Disturb" ? "Ne pas déranger" : nom]
        return c
    }

    // ——— Mémoire de Claude : remplissage du contexte (dernier « usage » du transcript de la session la plus récente) ———
    static func memoire(_ sessions: [String: [String: Any]], compressions: [Double], jour: String) -> [String: Any]? {
        let triees = sessions.values.sorted { (nombre($0["maj"]) ?? 0) > (nombre($1["maj"]) ?? 0) }
        guard let tp = triees.lazy.compactMap({ $0["transcript"] as? String }).first,
              let h = FileHandle(forReadingAtPath: tp) else { return nil }
        defer { try? h.close() }
        let taille = h.seekToEndOfFile()
        h.seek(toFileOffset: taille > 400_000 ? taille - 400_000 : 0)
        let bloc = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        for ligne in bloc.split(separator: "\n").reversed() where ligne.contains("\"usage\"") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(ligne.utf8)) as? [String: Any],
                  let m = o["message"] as? [String: Any], let u = m["usage"] as? [String: Any], !u.isEmpty else { continue }
            let tot = (nombre(u["input_tokens"]) ?? 0) + (nombre(u["cache_read_input_tokens"]) ?? 0) + (nombre(u["cache_creation_input_tokens"]) ?? 0)
            let mod = m["model"] as? String ?? ""
            let grand = ["opus-5", "sonnet-5", "fable", "[1m]"].contains { mod.contains($0) } || tot > 200_000
            let fen: Double = grand ? 1_000_000 : 200_000
            var r: [String: Any] = ["utilise": tot, "fenetre": fen, "pourcent": (1000 * tot / fen).rounded() / 10,
                                    "compressions_jour": compressions.filter { jourLocal($0) == jour }.count]
            if let d = compressions.last { r["derniere_compression"] = d }
            return r
        }
        return nil
    }
}
