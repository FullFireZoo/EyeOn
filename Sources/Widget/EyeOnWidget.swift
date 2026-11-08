// Widget de Bureau (WidgetKit) d’EyeOn : à épingler sur le Bureau comme Calendrier ou Notes.
// Lit ~/Library/Application Support/EyeOn/widget.json, écrit chaque seconde par l'app EyeOn
// (le widget est sandboxé : exception en lecture seule sur ce seul dossier).
// Ampoule : garder le Mac éveillé tant que Claude travaille (lien eyeon://eveil).
import WidgetKit
import SwiftUI
import os
let journal = Logger(subsystem: "fr.fullfirezoo.eyeon.widget", category: "timeline")

struct Tache: Decodable { let titre: String; let fait: Double?; let total: Double?; let debut: Double?; let fin: Double?; let detail: String?; let bloque: Bool? }
struct Evenement: Decodable { let t: Double?; let a: String? }
struct Session: Decodable { let statut: String?; let action: String?; let demande: String?; let maj: Double?; let depuis: Double?; let historique: [Evenement]? }
struct Agent: Decodable { let desc: String?; let statut: String?; let debut: Double?; let fin: Double? }
struct Donnees: Decodable { let now: Double; let eveil: Bool?; let dernier_fichier: String?; let sessions: [String: Session]?; let agents: [String: Agent]?; let taches: [Tache]? }

struct Entree: TimelineEntry { let date: Date; let d: Donnees?; var phase: Int = 0 }

func lire() -> Donnees? {
    // vrai dossier personnel (pas celui du conteneur sandbox)
    var home = NSHomeDirectory()
    if let pw = getpwuid(getuid()), let d = pw.pointee.pw_dir { home = String(cString: d) }
    guard let data = FileManager.default.contents(atPath: home + "/Library/Application Support/EyeOn/widget.json") else { return nil }
    return try? JSONDecoder().decode(Donnees.self, from: data)
}

struct Fournisseur: TimelineProvider {
    func placeholder(in c: Context) -> Entree { Entree(date: .now, d: nil) }
    func getSnapshot(in c: Context, completion: @escaping (Entree) -> Void) { completion(Entree(date: .now, d: lire())) }
    func getTimeline(in c: Context, completion: @escaping (Timeline<Entree>) -> Void) {
        journal.log("getTimeline demandée")
        let d = lire()
        if Etat(d).veille {
            // Veille : mascotte endormie (respiration + bulles) — une image par seconde, séquence rejouée en boucle
            let t0 = Date()
            // macOS refuse une séquence trop lourde (> ~10 Mo) : moins d'images d'avance pour les grands formats
            let n = c.family == .systemSmall ? 96 : c.family == .systemMedium ? 40 : 32
            let images = (0..<n).map { Entree(date: t0.addingTimeInterval(Double($0)), d: d, phase: $0 % phasesVeille) }
            completion(Timeline(entries: images, policy: .atEnd))
        } else if let t = Etat(d).tache, finEstimee(t) != nil {
            // Tâche en cours : une image toutes les 2 s pendant 1 min → l'anneau avance en continu
            let t0 = Date()
            completion(Timeline(entries: (0..<30).map { Entree(date: t0.addingTimeInterval(Double($0) * 2), d: d) }, policy: .atEnd))
        } else {
            completion(Timeline(entries: [Entree(date: .now, d: d)], policy: .after(.now.addingTimeInterval(60))))
        }
    }
}

// ——— Palette claire « nacrée » (couleurs système Apple, version claire) ———
let bleu = Color(red: 0.0, green: 0.48, blue: 1.0), vert = Color(red: 0.20, green: 0.78, blue: 0.35)
let orange = Color(red: 1.0, green: 0.58, blue: 0.0), gris = Color(red: 0.56, green: 0.56, blue: 0.58)
let jaune = Color(red: 1.0, green: 0.80, blue: 0.0), corail = Color(red: 0.93, green: 0.45, blue: 0.27)
// Couleurs de texte système : lisibles en clair, en sombre et quand macOS atténue les widgets du Bureau
let encre = Color.primary, encre2 = Color.secondary
let encre3 = Color.primary.opacity(0.38), voile = Color.primary.opacity(0.10)

func date(_ t: Double?) -> Date { Date(timeIntervalSince1970: t ?? Date().timeIntervalSince1970) }

// Fond nacré qui suit le mode du Mac : blanc nacré en clair, nacre graphite en sombre
struct Nacre: View {
    @Environment(\.colorScheme) var mode
    var body: some View {
        let sombre = mode == .dark
        ZStack {
            LinearGradient(colors: sombre ? [Color(red: 0.19, green: 0.19, blue: 0.21), Color(red: 0.11, green: 0.11, blue: 0.12)]
                                          : [Color(white: 1.0), Color(red: 0.965, green: 0.965, blue: 0.975)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 1.0, green: 0.70, blue: 0.62).opacity(sombre ? 0.12 : 0.35), .clear], center: .topLeading, startRadius: 0, endRadius: 260)
            RadialGradient(colors: [Color(red: 0.62, green: 0.75, blue: 1.0).opacity(sombre ? 0.12 : 0.35), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 280)
        }
    }
}

struct Etat {
    let s: Session?; let travaille: Bool; let attend: Bool; let couleur: Color; let libelle: String; let court: String
    let taches: [Tache]; let enCours: [Agent]; let agentsFinis: Int; let hist: [Evenement]; let eveil: Bool; let fichier: Bool
    let veille: Bool; let derniere: Double?; let instant: Date
    init(_ d: Donnees?, instant: Date = Date()) {
        self.instant = instant
        s = d?.sessions?.values.sorted { ($0.maj ?? 0) > ($1.maj ?? 0) }.first
        let now = Date().timeIntervalSince1970
        travaille = s?.statut == "travaille" && now - (s?.maj ?? 0) < 300
        attend = !travaille && s?.statut == "attend"
        couleur = travaille ? bleu : attend ? vert : gris
        libelle = travaille ? "Claude travaille" : attend ? "Claude t'attend" : "Claude au repos"
        court = travaille ? "En cours" : attend ? "À toi" : "Repos"
        taches = d?.taches ?? []
        let ag = Array(d?.agents?.values ?? Dictionary<String, Agent>().values)
        enCours = ag.filter { $0.statut == "en cours" }.sorted { ($0.debut ?? 0) < ($1.debut ?? 0) }
        agentsFinis = ag.filter { $0.statut == "terminé" }.count
        hist = Array((s?.historique ?? []).dropLast().reversed())
        eveil = d?.eveil == true
        fichier = d?.dernier_fichier != nil
        derniere = s?.maj
        let actives = (d?.taches ?? []).contains { $0.fin == nil }
        veille = !travaille && !actives && enCours.isEmpty && (s == nil || now - (s?.maj ?? 0) > 900)
    }
    var tache: Tache? { taches.first { $0.fin == nil } ?? taches.first }
}

func avancement(_ t: Tache?, a instant: Date? = nil) -> Double {
    guard let t, let total = t.total, total > 0 else { return 0 }
    let reel = min(1, (t.fait ?? 0) / total)
    // entre deux mises à jour, on prolonge au rythme observé (sans dépasser 99 % ni reculer)
    if let instant, let fin = finEstimee(t), let deb = t.debut {
        let estime = (instant.timeIntervalSince1970 - deb) / (fin.timeIntervalSince1970 - deb)
        return max(reel, min(0.99, estime))
    }
    return reel
}
func finEstimee(_ t: Tache) -> Date? {
    guard t.fin == nil, t.bloque != true, let deb = t.debut, let f = t.fait, let tot = t.total, f > 0, tot > f else { return nil }
    return date(deb).addingTimeInterval((Date().timeIntervalSince1970 - deb) / f * tot)
}

struct Vue: View {
    let e: Entree
    @Environment(\.widgetFamily) var famille
    var body: some View {
        let et = Etat(e.d, instant: e.date)
        Group {
            if et.veille { Veille(et: et, phase: e.phase, famille: famille) }
            else {
                switch famille {
                case .systemSmall: Petit(et: et)
                case .systemLarge: Grand(et: et)
                default: Moyen(et: et)
                }
            }
        }
        .foregroundStyle(.primary)
        .containerBackground(for: .widget) { Nacre() }
        .widgetURL(URL(string: "eyeon://ouvrir"))
    }
}

// ——— Briques ———
// Dégradé de bleus pour les anneaux emboîtés (extérieur → intérieur)
let bleusAnneaux: [(Color, Color)] = [
    (Color(red: 0.00, green: 0.30, blue: 0.85), Color(red: 0.05, green: 0.42, blue: 1.00)),   // bleu profond
    (Color(red: 0.00, green: 0.52, blue: 1.00), Color(red: 0.20, green: 0.64, blue: 1.00)),   // bleu vif
    (Color(red: 0.25, green: 0.72, blue: 0.98), Color(red: 0.45, green: 0.85, blue: 1.00)),   // bleu ciel
]

// Ordre des anneaux (extérieur → intérieur) : la tâche qui finira le plus tard à l'extérieur,
// puis les autres par temps restant ; les tâches terminées au plus près de l'étoile (la dernière finie tout au centre).
func ordreAnneaux(_ et: Etat) -> [Tache] {
    let maintenant = et.instant.timeIntervalSince1970
    func reste(_ t: Tache) -> Double {
        if let f = finEstimee(t) { return ((f.timeIntervalSince1970 - maintenant) / 30).rounded() }   // paliers de 30 s : évite les échanges incessants
        return 1e9 * (1 - avancement(t))                                                                  // sans estimation : d'après ce qui reste à faire
    }
    let enCours = et.taches.filter { $0.fin == nil }.sorted { reste($0) > reste($1) }
    let finies = et.taches.filter { $0.fin != nil }.sorted { ($0.fin ?? 0) < ($1.fin ?? 0) }
    let derniereFinie = Array(finies.suffix(1))                       // la dernière terminée reste visible, au centre
    return Array(enCours.prefix(3 - derniereFinie.count)) + derniereFinie
}

// Un anneau à dessiner (tâche, ou anneau « au repos » quand il n'y a pas de tâche)
struct ItemAnneau { let id: String; let p: Double; let c1: Color; let c2: Color; let fini: Bool }

struct Anneau: View {   // l'étoile orange au centre ; un anneau par tâche en cours (3 max), comme les anneaux Activité
    let et: Etat; var taille: CGFloat = 76; var epaisseur: CGFloat = 9
    var body: some View {
        let taches = ordreAnneaux(et)
        // pas de tâche : un seul anneau « au repos », géré exactement comme les autres (même identité stable)
        let items: [ItemAnneau] = taches.isEmpty
            ? [ItemAnneau(id: "repos", p: et.travaille ? 1 : 0, c1: et.travaille ? bleusAnneaux[0].0 : et.couleur, c2: et.travaille ? bleusAnneaux[0].1 : et.couleur, fini: false)]
            : taches.enumerated().map { k, t in
                let (c1, c2) = t.bloque == true ? (orange.opacity(0.8), orange) : bleusAnneaux[min(k, 2)]
                return ItemAnneau(id: t.titre, p: avancement(t, a: et.instant), c1: c1, c2: c2, fini: t.fin != nil)
            }
        let n = items.count
        let ep = n == 1 ? epaisseur : epaisseur * (n == 2 ? 0.78 : 0.64)
        let ecart = ep * 0.35
        let interieur = taille - CGFloat(n - 1) * 2 * (ep + ecart) - ep * 2
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { k, it in
                let d = taille - CGFloat(k) * 2 * (ep + ecart)
                ZStack {
                    Circle().stroke(voile, lineWidth: ep)
                    // arc bleu (toujours plein dessous) et arc vert par-dessus qui apparaît en fondu à la fin
                    Circle().trim(from: 0, to: max(0.001, it.p))
                        .stroke(AngularGradient(colors: [it.c1, it.c2], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(it.p, 0.05))),
                                style: StrokeStyle(lineWidth: ep, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Circle().trim(from: 0, to: max(0.001, it.p))
                        .stroke(AngularGradient(colors: [vert.opacity(0.75), vert], center: .center), style: StrokeStyle(lineWidth: ep, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .opacity(it.fini ? 1 : 0)
                        .animation(.easeInOut(duration: 1.2), value: it.fini)   // fondu enchaîné bleu → vert (opacité seulement)
                }
                .frame(width: d, height: d)
                // UNE seule animation pour tout l'anneau (fond, arc, épaisseur, taille) : il bouge d'un bloc
                .animation(.linear(duration: 2.0), value: [it.p, Double(d), Double(ep)])
                .shadow(color: (it.fini ? vert : it.c2).opacity(0.3), radius: 2.5)
                .transition(.opacity)   // un anneau qui part s'efface en entier (fond + arc ensemble)
            }
            Image(systemName: !taches.isEmpty || et.travaille ? "sparkle" : et.attend ? "checkmark" : "moon.zzz")
                .font(.system(size: max(10, interieur * 0.5), weight: .semibold))
                .foregroundStyle(!taches.isEmpty || et.travaille ? corail : et.couleur)
        }
        .frame(width: taille, height: taille)
        .animation(.linear(duration: 2.0), value: items.map(\.id))   // arrivées / départs d'anneaux au même rythme
    }
}

struct Pastille: View {
    let et: Etat
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(et.couleur).frame(width: 6, height: 6)
            Text(et.court).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(et.couleur)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(et.couleur.opacity(0.12)))
    }
}

struct Chrono: View {
    let et: Etat; var taille: CGFloat = 11
    var body: some View {
        if et.travaille, let dep = et.s?.depuis ?? et.s?.maj {
            Text(date(dep), style: .timer).font(.system(size: taille, weight: .medium, design: .rounded)).foregroundStyle(encre2)
                .monospacedDigit().multilineTextAlignment(.trailing)
        }
    }
}

struct Rond: View {   // bouton rond (terminal, fichier, ampoule)
    let symbole: String; let lien: String; var actif = false; var couleur = jaune
    var body: some View {
        Link(destination: URL(string: "eyeon://" + lien)!) {
            Image(systemName: symbole)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(actif ? Color.black.opacity(0.7) : encre2)
                .frame(width: 24, height: 24)
                .background(Circle().fill(actif ? couleur : voile))
                .shadow(color: actif ? couleur.opacity(0.55) : .clear, radius: 4)
        }
    }
}

struct Boutons: View {
    let et: Etat; var terminal = true
    var body: some View {
        HStack(spacing: 6) {
            if terminal { Rond(symbole: "terminal", lien: "terminal") }
            if et.fichier { Rond(symbole: "doc.text", lien: "fichier") }
            Rond(symbole: et.eveil ? "lightbulb.fill" : "lightbulb", lien: "eveil", actif: et.eveil)
        }
    }
}

struct Titre: View {
    let t: String
    var body: some View { Text(t.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.6).foregroundStyle(encre3) }
}

struct Carte<C: View>: View {
    @ViewBuilder let contenu: C
    @Environment(\.colorScheme) var mode
    var body: some View {
        VStack(alignment: .leading, spacing: 6) { contenu }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(mode == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.75))
                .shadow(color: .black.opacity(mode == .dark ? 0 : 0.06), radius: 6, y: 2))
    }
}

struct Barre: View {
    let t: Tache; var detail = true
    var body: some View {
        let p = avancement(t)
        let c = t.fin != nil ? vert : t.bloque == true ? orange : bleu
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text((t.fin != nil ? "✓ " : "") + t.titre).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int(p * 100)) %").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(c).monospacedDigit()
            }
            if let fin = finEstimee(t) {
                ProgressView(timerInterval: date(t.debut)...fin, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.linear).tint(c)
            } else {
                ProgressView(value: p).progressViewStyle(.linear).tint(c)
            }
            if detail {
                HStack(spacing: 3) {
                    if let tot = t.total { Text("\(Int(t.fait ?? 0)) sur \(Int(tot))") }
                    if let fin = finEstimee(t) { Text("· fin"); Text(fin, style: .relative) }
                    else if t.fin != nil { Text("· terminé") }
                    else if t.bloque == true { Text("· en pause").foregroundStyle(orange) }
                }.font(.system(size: 10)).foregroundStyle(encre2).lineLimit(1)
            }
        }
    }
}

// Ligne compacte d'une tâche, avec la couleur de son anneau (format moyen, plusieurs tâches)
struct BarrePastille: View {
    let t: Tache; let k: Int; let et: Etat
    var body: some View {
        let c = t.fin != nil ? vert : bleusAnneaux[min(k, 2)].1
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text(t.titre).font(.system(size: 11, weight: .medium)).lineLimit(1)
            Spacer(minLength: 2)
            Text("\(Int(avancement(t, a: et.instant) * 100)) %").font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(c).monospacedDigit()
        }
        .animation(.easeInOut(duration: 1.2), value: t.fin != nil)
    }
}

struct LigneAnneau: View {   // grand format : une ligne par anneau, aux couleurs de l'anneau
    let t: Tache; let k: Int; let et: Etat
    var body: some View {
        let fini = t.fin != nil
        let c = fini ? vert : t.bloque == true ? orange : bleusAnneaux[min(k, 2)].1
        let p = avancement(t, a: et.instant)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(c).frame(width: 7, height: 7)
                Text((fini ? "✓ " : "") + t.titre).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 2)
                if let fin = finEstimee(t) { Text(fin, style: .relative).font(.system(size: 9.5)).foregroundStyle(encre3).lineLimit(1) }
                Text("\(Int(p * 100)) %").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(c).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(voile)
                    Capsule().fill(LinearGradient(colors: [c.opacity(0.75), c], startPoint: .leading, endPoint: .trailing)).frame(width: max(3, g.size.width * p))
                }
            }.frame(height: 4)
        }
        .animation(.linear(duration: 2.0), value: p)
        .animation(.easeInOut(duration: 1.2), value: fini)
    }
}

struct LigneAgent: View {
    let a: Agent
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "person.fill").font(.system(size: 8)).foregroundStyle(.white)
                .frame(width: 16, height: 16).background(Circle().fill(bleu))
            Text(a.desc ?? "Agent").font(.system(size: 11.5)).lineLimit(1)
            Spacer(minLength: 2)
            Text(date(a.debut), style: .timer).font(.system(size: 10.5, design: .rounded)).foregroundStyle(encre2).monospacedDigit()
                .multilineTextAlignment(.trailing).frame(maxWidth: 46)
        }
    }
}

struct LigneHist: View {
    let h: Evenement
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(vert.opacity(0.85)).frame(width: 5, height: 5)
            Text(h.a ?? "").font(.system(size: 11)).foregroundStyle(encre2).lineLimit(1)
            Spacer(minLength: 2)
            if let t = h.t { Text(date(t), style: .time).font(.system(size: 10, design: .rounded)).foregroundStyle(encre3) }
        }
    }
}

struct Action: View {
    let et: Etat; var lignes = 2; var taille: CGFloat = 12.5
    var body: some View {
        if et.travaille, let a = et.s?.action {
            Text(a).font(.system(size: taille, weight: .medium)).lineLimit(lignes)
        } else if et.attend {
            Text("Terminé, à toi de jouer").font(.system(size: taille, weight: .medium)).foregroundStyle(vert).lineLimit(1)
        } else {
            Text("Rien en cours").font(.system(size: taille)).foregroundStyle(encre2)
        }
    }
}

// ——— PETIT : un grand anneau, l'état, le chrono ———
struct Petit: View {
    let et: Etat
    var body: some View {
        VStack(spacing: 6) {
            HStack { Pastille(et: et); Spacer(); Chrono(et: et, taille: 10.5) }
            Spacer(minLength: 0)
            Anneau(et: et, taille: 70, epaisseur: 8)
            Spacer(minLength: 0)
            if let t = et.tache {
                HStack(spacing: 4) {
                    Text("\(Int(avancement(t, a: et.instant) * 100)) %").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(bleu).monospacedDigit()
                        .contentTransition(.numericText(value: avancement(t, a: et.instant))).animation(.linear(duration: 2.0), value: avancement(t, a: et.instant))
                    Text(t.titre).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    let autres = et.taches.filter { $0.fin == nil }.count - 1
                    if autres > 0 { Text("+\(autres)").font(.system(size: 10, weight: .bold)).foregroundStyle(encre2) }
                }
            } else {
                Text(et.travaille ? (et.s?.action ?? "") : et.libelle).font(.system(size: 11, weight: .semibold)).lineLimit(1).multilineTextAlignment(.center)
            }
        }
    }
}

// ——— MOYEN : anneau à gauche, détail à droite ———
struct Moyen: View {
    let et: Etat
    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 6) {
                Anneau(et: et, taille: 84, epaisseur: 9)
                Chrono(et: et, taille: 11)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(et.libelle).font(.system(size: 14, weight: .bold))
                    Spacer(minLength: 2)
                    Boutons(et: et)
                }
                Action(et: et, lignes: 2, taille: 12)
                Spacer(minLength: 0)
                if et.taches.count > 1 {
                    ForEach(Array(ordreAnneaux(et).enumerated()).reversed(), id: \.element.titre) { k, t in BarrePastille(t: t, k: k, et: et) }
                } else if let t = et.tache { Barre(t: t) }
                else if !et.enCours.isEmpty {
                    Label("\(et.enCours.count) agent\(et.enCours.count > 1 ? "s" : "") en parallèle", systemImage: "person.2.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(bleu)
                } else if let h = et.hist.first { LigneHist(h: h) }
            }
        }
    }
}

// ——— GRAND : tableau de bord ———
struct Grand: View {
    let et: Etat
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Anneau(et: et, taille: et.taches.count > 1 ? 52 : 46, epaisseur: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(et.libelle).font(.system(size: 16, weight: .bold))
                    HStack(spacing: 6) { Pastille(et: et); Chrono(et: et, taille: 11) }
                }
                Spacer()
                Boutons(et: et)
            }
            Carte {
                Titre(t: "En ce moment")
                Action(et: et, lignes: et.taches.count > 1 ? 1 : 2, taille: 13)
                if let dem = et.s?.demande {
                    Text("« \(dem) »").font(.system(size: 11)).foregroundStyle(encre2).lineLimit(et.taches.count > 1 ? 1 : 2)
                }
            }
            if et.taches.count > 1 {
                Carte {
                    Titre(t: "Progression")
                    ForEach(Array(ordreAnneaux(et).enumerated()).reversed(), id: \.element.titre) { k, t in LigneAnneau(t: t, k: k, et: et) }
                }
            } else if let t = et.taches.first {
                Carte { Titre(t: "Progression"); Barre(t: t) }
            }
            if !et.enCours.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Titre(t: "Agents · \(et.enCours.count) en cours")
                    ForEach(Array(et.enCours.prefix(et.taches.count > 1 ? 1 : 2).enumerated()), id: \.offset) { _, a in LigneAgent(a: a) }
                }
            }
            if et.taches.count <= 1 || et.enCours.isEmpty { VStack(alignment: .leading, spacing: 5) {
                Titre(t: "Récemment")
                let n = et.taches.count > 1 ? 2 : 6 - 2 * min(2, et.taches.count) - min(2, et.enCours.count)
                ForEach(Array(et.hist.prefix(max(2, n)).enumerated()), id: \.offset) { _, h in LigneHist(h: h) }
            }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// ——— Mascotte endormie : le petit axolotl doré en pixel art ———
// Référence exacte du dessin, des couleurs et des animations : design/mascotte-reference.html (mode « dort1 »).
// Le sprite fait 24 × 13 cases. Chaque couleur est dessinée d'un seul tenant (une seule Path par couleur),
// comme un sprite de jeu vidéo ; les bulles sont des vues à part pour pouvoir glisser d'une image à l'autre.
// Le panneau de la barre des menus a son équivalent en JavaScript (Resources/panneau.html).
let phasesVeille = 8   // une image par seconde ; l'animation boucle sur 8 s (2 respirations, 2 tours de bulles)

enum SpriteMascotte {
    // B corps, W ventre, E trou (yeux, bouche) ; « . » vide
    static let corps = [
        "........................",
        "........................",
        "......BBBBBBBBBBBB......",
        ".....BBBBBBBBBBBBBB.....",
        "....BBBBBBBBBBBBBBBB....",
        "....BBBEBBBBBBBBEBBB....",
        "..BBBBBEBBBBBBBBEBBBBB..",
        "....BBBBBBEEEEBBBBBB....",
        "....BBBWWWWWWWWWWBBB....",
        "....BBBWWWWWWWWWWBBB....",
        "....BBBBBBBBBBBBBBBB....",
        "....BB.BB......BB.BB....",
        "........................"]
    // Branchies détendues du sommeil, côté gauche en (x, y) ; le côté droit est leur miroir
    static let branchiesCalmes = [(1, 2), (2, 2), (2, 3), (3, 3), (4, 3), (0, 4), (1, 4), (2, 4), (3, 4), (1, 5), (2, 5), (0, 6)]

    // Grille de la pose endormie : yeux fermés en petit arc sombre (K), joues roses (P), bouche « mini », branchies (G)
    static let grille: [[Character]] = {
        var g = corps.map { Array($0) }
        for (y, x) in [(5, 7), (6, 7), (5, 16), (6, 16)] { g[y][x] = "B" }                       // on referme les yeux
        for (y, x) in [(5, 6), (6, 7), (6, 8), (5, 9), (5, 17), (6, 16), (6, 15), (5, 14)] { g[y][x] = "K" }
        for (y, x) in [(7, 6), (7, 7), (7, 16), (7, 17)] { g[y][x] = "P" }
        for x in [10, 11, 13] { g[7][x] = "B" }                                                  // bouche réduite à un point
        for (x, y) in branchiesCalmes { g[y][x] = "G"; g[y][23 - x] = "G" }
        return g
    }()

    // Un calque = une couleur et toutes ses cases. Ombre (S) : bord droit, bas du corps et rangée 10 ;
    // franges extérieures des branchies (Gf) plus foncées.
    static let calques: [(couleur: Color, cases: [(Int, Int)])] = {
        let teintes: [String: UInt32] = ["B": 0xF2B544, "S": 0xD69A2E, "W": 0xFFF3CF, "G": 0xF08A5D, "Gf": 0xD9673B, "K": 0x3A2410, "P": 0xF59A8C]
        var cases: [String: [(Int, Int)]] = [:]
        let g = grille, h = g.count
        for y in 0..<h {
            let droite = g[y].lastIndex(of: "B") ?? -1
            for (x, c) in g[y].enumerated() where c != "." && c != "E" {
                var cle = String(c)
                if c == "B" && (x == droite || (y + 1 < h && g[y + 1][x] == ".") || y == 10) { cle = "S" }
                if c == "G" && (x <= 1 || x >= 22) { cle = "Gf" }
                cases[cle, default: []].append((x, y))
            }
        }
        return ["B", "S", "W", "G", "Gf", "K", "P"].compactMap { cle in
            guard let l = cases[cle], let t = teintes[cle] else { return nil }
            return (Color(red: Double(t >> 16 & 0xFF) / 255, green: Double(t >> 8 & 0xFF) / 255, blue: Double(t & 0xFF) / 255), l)
        }
    }()
    // Dernière case pleine de chaque rangée (pour la respiration)
    static let derniere: [Int] = grille.map { $0.lastIndex { $0 != "." } ?? -1 }
}

// Les cases d'une couleur, en une seule Path. Respiration : le ventre (rangées 8 à 10) s'élargit d'1 point de chaque côté.
struct CalquePixels: Shape {
    let cases: [(Int, Int)]; let respire: Bool
    func path(in r: CGRect) -> Path {
        let px = r.width / 24
        var p = Path()
        for (x, y) in cases {
            var c = CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: px, height: px)
            if respire && (8...10).contains(y) {
                c.origin.x -= 1
                if x == SpriteMascotte.derniere[y] { c.size.width += 2 }
            }
            p.addRect(c)
        }
        return p
    }
}

// Trois bulles qui montent à côté de la tête, grossissent et s'effacent (un tour toutes les 4 s, décalées d'un tiers).
// Entre deux images (1 s), la montée glisse en continu ; une bulle qui recommence en bas est une nouvelle vue (fondu).
struct BullesMascotte: View {
    let px: CGFloat; let phase: Int
    @Environment(\.colorScheme) var mode
    struct Bulle { let id: String; let x: CGFloat; let y: CGFloat; let r: CGFloat; let alpha: Double }
    var bulles: [Bulle] {
        (0..<3).map { i in
            let u = Double(phase) / 4 + Double(i) / 3, ph = u - u.rounded(.down)
            return Bulle(id: "\(i)-\(Int(u))",
                         x: (21 + sin(ph * 6 + Double(i)) * 0.9) * px, y: (2.5 - ph * 7) * px,
                         r: px * (0.4 + ph * 0.5), alpha: (1 - ph) * 0.9)
        }
    }
    var body: some View {
        let trait = mode == .dark ? Color(red: 0.75, green: 0.89, blue: 1.0) : Color(red: 0.50, green: 0.72, blue: 0.90)
        ZStack(alignment: .topLeading) {
            ForEach(bulles, id: \.id) { b in
                ZStack(alignment: .topLeading) {
                    Circle().stroke(trait, lineWidth: max(1, px * 0.32))
                    Rectangle().fill(.white).frame(width: px * 0.3, height: px * 0.3).offset(x: b.r * 0.55, y: b.r * 0.55)   // reflet
                }
                .frame(width: 2 * b.r, height: 2 * b.r, alignment: .topLeading)
                .opacity(b.alpha)
                .offset(x: b.x - b.r, y: b.y - b.r)
                .transition(.opacity)
            }
        }
        .frame(width: 24 * px, height: 13 * px, alignment: .topLeading)
        .animation(.linear(duration: 1), value: phase)
    }
}

// L'axolotl endormi, assis : la vue occupe exactement la grille (24 × 13 cases de px points) ;
// les bulles débordent au-dessus, dans l'espace libre.
struct MascotteEndormie: View {
    var px: CGFloat = 5; var phase = 0
    @Environment(\.colorScheme) var mode
    var body: some View {
        let respire = phase % 4 >= 2   // 2 s inspiration, 2 s expiration
        ZStack(alignment: .topLeading) {
            // petite ombre au sol
            Rectangle().fill(Color.black.opacity(mode == .dark ? 0.35 : 0.08))
                .frame(width: 14 * px, height: 0.7 * px).offset(x: 5 * px, y: 12.4 * px)
            ForEach(Array(SpriteMascotte.calques.enumerated()), id: \.offset) { _, calque in
                CalquePixels(cases: calque.cases, respire: respire).fill(calque.couleur)
            }
            BullesMascotte(px: px, phase: phase)
        }
        .frame(width: 24 * px, height: 13 * px, alignment: .topLeading)
        .accessibilityLabel("Mascotte endormie")
    }
}

// ——— VEILLE : Claude n'est pas connecté ———
// La famille est passée en paramètre (et non lue dans l'environnement) pour pouvoir rendre la vue hors widget.
struct Veille: View {
    let et: Etat; let phase: Int; let famille: WidgetFamily
    var inactif: some View {
        Group {
            if let t = et.derniere {
                HStack(spacing: 4) { Text("Inactif depuis").foregroundStyle(encre3); Text(date(t), style: .relative).foregroundStyle(encre2) }
            } else { Text("Aucune session ouverte").foregroundStyle(encre2) }
        }
        .font(.system(size: famille == .systemLarge ? 11.5 : 11, weight: .medium)).lineLimit(1)
    }
    var body: some View {
        switch famille {
        case .systemSmall:
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                MascotteEndormie(px: 5, phase: phase).padding(.top, 14)
                Spacer(minLength: 0)
                Text("En veille").font(.system(size: 12, weight: .semibold)).foregroundStyle(encre2)
            }
        case .systemLarge:
            VStack(spacing: 6) {
                MascotteEndormie(px: 8, phase: phase).padding(.top, 34)
                Text("Claude en veille").font(.system(size: 17, weight: .bold)).padding(.top, 6)
                inactif
                Spacer(minLength: 4)
                if !et.hist.isEmpty {
                    Carte {
                        Titre(t: "Dernières actions")
                        ForEach(Array(et.hist.prefix(3).enumerated()), id: \.offset) { _, h in LigneHist(h: h) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .topTrailing) { Boutons(et: et) }
        default:
            HStack(spacing: 14) {
                MascotteEndormie(px: 5, phase: phase).padding(.top, 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Claude en veille").font(.system(size: 15, weight: .bold))
                    inactif
                    if let h = et.hist.first { LigneHist(h: h).padding(.top, 8) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) { Boutons(et: et) }
        }
    }
}

@main
struct EyeOnWidgetBundle: WidgetBundle {
    var body: some Widget { EyeOnWidget() }
}

struct EyeOnWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EyeOn", provider: Fournisseur()) { e in Vue(e: e) }
            .configurationDisplayName("EyeOn")
            .description("Ce que Claude Code est en train de faire, avec les anneaux de progression.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
