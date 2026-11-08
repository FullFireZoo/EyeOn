// EyeOn — app de la barre des menus qui montre en direct ce que fait Claude Code.
// • Icône dans la barre des menus : un clic ouvre la progression en direct + les réglages.
// • Fenêtre flottante optionnelle (visible partout, même en plein écran, clics traversants).
// • Prévient (notification + bulle) quand une tâche est finie — en attendant que le micro soit libre (dictée).
// • Ampoule (widget, panneau) : empêche le Mac de se mettre en veille tant que Claude travaille.
// • ⌥ Espace ouvre le panneau ; résumé de la journée ; raccourcis (terminal, dernier fichier).
// • Ne pas déranger (manuel, ou auto pendant une vidéo) ; rappel « Claude t'attend » ; alerte iPhone (iMessage) si absent.
// • Alimente le widget de Bureau (WidgetKit) : écrit widget.json dans le dossier de données chaque seconde.
import Cocoa
import WebKit
import WidgetKit
import IOKit.pwr_mgt
import UserNotifications
import CoreAudio
import Carbon.HIToolbox

import ServiceManagement

let dossierApp = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
let sortieWidget = EyeOn.chemin("widget.json")
let page = Bundle.main.path(forResource: "panneau", ofType: "html") ?? dossierApp + "/../Resources/panneau.html"
let reglages = UserDefaults.standard
/// Binaire embarqué appelé par les hooks de Claude Code.
var binaireHook: String { Bundle.main.bundlePath + "/Contents/MacOS/eyeon-hook" }

func nouvelleVue(_ mode: String, _ handler: WKScriptMessageHandler) -> WKWebView {
    let conf = WKWebViewConfiguration()
    for nom in ["hauteur", "action"] { conf.userContentController.add(handler, name: nom) }
    let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 340, height: 120), configuration: conf)
    w.setValue(false, forKey: "drawsBackground")
    var url = URLComponents(url: URL(fileURLWithPath: page), resolvingAgainstBaseURL: false)!
    url.queryItems = [URLQueryItem(name: "mode", value: mode)]
    w.loadFileURL(url.url!, allowingReadAccessTo: URL(fileURLWithPath: (page as NSString).deletingLastPathComponent))
    return w
}

final class Appli: NSObject, NSApplicationDelegate, WKScriptMessageHandler, NSPopoverDelegate {
    var fenetre: NSPanel!
    var webFenetre: WKWebView!
    var webPopover: WKWebView!
    var popover = NSPopover()
    var barre: NSStatusItem!
    var hauteurFenetre: CGFloat = 120
    let largeur: CGFloat = 340
    var dernierJSON = ""
    var derniereSignature = ""
    var derniereAction = ""
    var dernierRechargement = Date.distantPast
    var assertion: IOPMAssertionID = 0
    var assertionActive = false
    var tachesFinies = Set<String>()
    var premierPassage = true
    var debutTravail: Double? = nil
    var demandeEnCours = ""
    var messageFini: String? = nil
    var fermeture: Timer? = nil
    var compact = false
    var fermetureAuto = false
    var enAttente: (titre: String, texte: String)? = nil
    var attenteDepuis: Date? = nil
    var titreBulle = "Tâche terminée"
    var rappelPour: Double? = nil
    var raccourci: EventHotKeyRef? = nil

    var coin: Int { get { reglages.integer(forKey: "coin") } set { reglages.set(newValue, forKey: "coin") } }
    var flottante: Bool { get { reglages.bool(forKey: "flottante") } set { reglages.set(newValue, forKey: "flottante") } }
    var eveil: Bool { get { reglages.bool(forKey: "eveil") } set { reglages.set(newValue, forKey: "eveil") } }
    var nePasDeranger: Bool { get { reglages.bool(forKey: "nePasDeranger") } set { reglages.set(newValue, forKey: "nePasDeranger") } }
    var rappels: Bool { get { reglages.object(forKey: "rappels") == nil ? true : reglages.bool(forKey: "rappels") } set { reglages.set(newValue, forKey: "rappels") } }
    var iphone: String { (reglages.string(forKey: "iphone") ?? "").trimmingCharacters(in: .whitespaces) }   // numéro ou adresse iMessage (fenêtre Réglages)
    var iphoneActif: Bool { get { reglages.object(forKey: "iphoneActif") == nil ? true : reglages.bool(forKey: "iphoneActif") } set { reglages.set(newValue, forKey: "iphoneActif") } }
    var reglagesOuverts: Bool { get { reglages.bool(forKey: "reglagesOuverts") } set { reglages.set(newValue, forKey: "reglagesOuverts") } }
    var notifs: Bool { get { reglages.object(forKey: "notifs") == nil ? true : reglages.bool(forKey: "notifs") } set { reglages.set(newValue, forKey: "notifs") } }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        EyeOn.creerDossier()
        reparerConnexion()
        if reglages.bool(forKey: "assistantTermine") { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }

        // Icône de la barre des menus
        barre = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = barre.button {
            b.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "EyeOn")
            b.image?.isTemplate = true
            b.action = #selector(clicIcone)
            b.target = self
        }
        let vc = NSViewController()
        webPopover = nouvelleVue("popover", self)
        vc.view = webPopover
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: largeur, height: 200)
        popover.delegate = self
        popover.appearance = NSAppearance(named: .darkAqua)   // le panneau reste toujours sombre
        webPopover.appearance = NSAppearance(named: .darkAqua)

        // Fenêtre flottante (désactivée par défaut)
        fenetre = NSPanel(contentRect: NSRect(x: 0, y: 0, width: largeur, height: hauteurFenetre),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        fenetre.isOpaque = false; fenetre.backgroundColor = .clear; fenetre.hasShadow = true
        fenetre.level = .floating
        fenetre.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        fenetre.ignoresMouseEvents = true
        let verre = NSVisualEffectView(frame: fenetre.contentView!.bounds)
        verre.autoresizingMask = [.width, .height]
        verre.material = .hudWindow; verre.blendingMode = .behindWindow; verre.state = .active
        verre.wantsLayer = true; verre.layer?.cornerRadius = 22; verre.layer?.masksToBounds = true
        verre.appearance = NSAppearance(named: .vibrantDark)
        webFenetre = nouvelleVue("fenetre", self)
        webFenetre.frame = verre.bounds; webFenetre.autoresizingMask = [.width, .height]
        verre.addSubview(webFenetre)
        fenetre.contentView = verre
        placer()
        if flottante { fenetre.orderFrontRegardless() }

        installerRaccourci()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.rafraichir() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.placer() }
        rafraichir()
        if !reglages.bool(forKey: "assistantTermine") { Fenetres.assistant() }
    }

    // L'app a été déplacée (ou mise à jour ailleurs) : on remet nos hooks sur le bon binaire, sans rien toucher d'autre.
    func reparerConnexion() {
        guard let cmd = ConnexionClaude.commandeInstallee(), cmd != ConnexionClaude.commande(pour: binaireHook),
              Emplacement.estDefinitif else { return }
        _ = try? ConnexionClaude.connecter(binaire: binaireHook)
    }

    // Liens du widget : eyeon://eveil (ampoule), eyeon://terminal, eyeon://fichier, eyeon://ouvrir…
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls {
            if u.host == "eveil" { basculerEveil() }
            else if u.host == "widget" { WidgetCenter.shared.reloadAllTimelines() }
            else if u.host == "terminal" { ouvrirTerminal() }
            else if u.host == "testiphone" { testerIphone() }
            else if u.host == "reglages" { Fenetres.reglages() }
            else if u.host == "fichier" { ouvrirDernierFichier(dossier: false) }
            else if u.host == "dossier" { ouvrirDernierFichier(dossier: true) }
            else { ouvrirPanneau(auto: false) }
        }
    }

    @objc func clicIcone() {
        if popover.isShown && !compact { popover.performClose(nil) } else { messageFini = nil; compact = false; ouvrirPanneau(auto: false) }
    }

    func ouvrirPanneau(auto: Bool) {
        guard let b = barre.button else { return }
        fermeture?.invalidate()
        compact = auto
        if !dernierJSON.isEmpty { pousser(webPopover, dernierJSON) }
        if !popover.isShown { popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY) }
        if !auto { marquerVus() }
        if auto {  // bulle « terminé » : se referme seule après 15 s si on ne la déplie pas
            fermeture = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
                self?.fermetureAuto = true; self?.popover.performClose(nil); self?.messageFini = nil }
        } else { popover.contentViewController?.view.window?.makeKey() }
    }

    func basculerEveil() {
        eveil.toggle()
        majEveil(travaille: estEnTravail(dernierJSON))
        WidgetCenter.shared.reloadAllTimelines()
        if !dernierJSON.isEmpty { pousser(webPopover, dernierJSON) }
    }

    func popoverDidClose(_ notification: Notification) {
        messageFini = nil; compact = false; fermeture?.invalidate()
        if !fermetureAuto { marquerVus() }   // refermée toute seule (tu n'étais peut-être pas là) : pas « vue »
        fermetureAuto = false
    }

    // Tu as vu la fin des tâches (bulle consultée/fermée, panneau ouvert, ou déjà dans le terminal) :
    // lire.py retirera leur anneau vert 20 s plus tard.
    func marquerVus() {
        guard let d = try? JSONSerialization.jsonObject(with: Data(dernierJSON.utf8)) as? [String: Any] else { return }
        let chemin = EyeOn.chemin("vus.json")
        var vus = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: chemin)))) as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        for t in d["taches"] as? [[String: Any]] ?? [] where t["fin"] != nil {
            let titre = t["titre"] as? String ?? ""
            let debut = Lecteur.cleNombre(t["debut"])
            let cle = "\(titre)|\(debut)"
            if vus[cle] == nil { vus[cle] = now }
        }
        vus = vus.filter { now - $0.value < 86400 }
        if let data = try? JSONSerialization.data(withJSONObject: vus) { try? data.write(to: URL(fileURLWithPath: chemin)) }
    }

    // Claude « travaille » : session active, barre de progression en cours ou agent en cours.
    func estEnTravail(_ json: String) -> Bool {
        guard let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return false }
        let now = d["now"] as? Double ?? Date().timeIntervalSince1970
        let s = (d["sessions"] as? [String: [String: Any]] ?? [:]).values.contains { ($0["statut"] as? String) == "travaille" && now - ($0["maj"] as? Double ?? 0) < 300 }
        let t = (d["taches"] as? [[String: Any]] ?? []).contains { $0["fin"] == nil && $0["bloque"] == nil }
        let a = (d["agents"] as? [String: [String: Any]] ?? [:]).values.contains { ($0["statut"] as? String) == "en cours" }
        return s || t || a
    }

    // Priorités : micro en cours (dictée) → on attend ; vidéo/visio → on attend (max 30 min) ;
    // « Ne pas déranger » → notification silencieuse sans bulle. Absent du Mac → copie sur l'iPhone.
    func livrerSiPossible() {
        guard let alerte = enAttente else { return }
        // Tu es déjà dans le terminal de Claude : pas besoin de te prévenir
        if let devant = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, devant == (valeur("terminal") ?? "com.apple.Terminal") {
            enAttente = nil; marquerVus(); return
        }
        let attente = Date().timeIntervalSince(attenteDepuis ?? Date())
        let micro = microActif(), video = videoEnCours()
        if micro && attente < 600 { return }
        if video && attente < 1800 { return }
        enAttente = nil
        let discret = nePasDeranger || concentrationMac() || micro || video
        let c = UNMutableNotificationContent()
        c.title = alerte.titre; c.body = alerte.texte
        if !discret { c.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        if absent() { envoyerIphone(alerte.titre + " — " + alerte.texte) }
        if !discret { messageFini = alerte.texte; titreBulle = alerte.titre.replacingOccurrences(of: "✓ ", with: ""); ouvrirPanneau(auto: true) }
    }

    // ——— Raccourci clavier global ⌥ Espace (API Carbon : aucune autorisation nécessaire) ———
    func installerRaccourci() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            let moi = Unmanaged<Appli>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { moi.clicIcone() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x4559454F), id: 1) // 'EYEO'
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &raccourci)
    }

    // ——— Raccourcis d'action ———
    func valeur(_ cle: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(dernierJSON.utf8)) as? [String: Any])?[cle] as? String
    }
    func ouvrirTerminal() {
        let id = valeur("terminal") ?? "com.apple.Terminal"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        popover.performClose(nil)
    }
    func ouvrirDernierFichier(dossier: Bool) {
        guard let f = valeur("dernier_fichier"), FileManager.default.fileExists(atPath: f) else { return }
        if dossier { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f)]) }
        else { NSWorkspace.shared.open(URL(fileURLWithPath: f)) }
        popover.performClose(nil)
    }

    // ——— Ne pas déranger automatique : une autre app empêche l'écran de s'éteindre (vidéo, visio) ———
    func videoEnCours() -> Bool {
        var dico: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dico) == kIOReturnSuccess, let d = dico?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        let moi = ProcessInfo.processInfo.processIdentifier
        for (pid, liste) in d where pid.int32Value != moi {
            for a in liste where (a["AssertType"] as? String) == "PreventUserIdleDisplaySleep" || (a["AssertType"] as? String) == "NoDisplaySleepAssertion" { return true }
        }
        return false
    }

    // ——— Concentration / Ne pas déranger du Mac (lue par Lecteur dans ~/Library/DoNotDisturb) ———
    func concentrationMac() -> Bool {
        ((try? JSONSerialization.jsonObject(with: Data(dernierJSON.utf8)) as? [String: Any])?["concentration"] as? [String: Any])?["actif"] as? Bool ?? false
    }

    // ——— Absent du Mac : inactif depuis 5 min ou écran verrouillé ———
    func absent() -> Bool {
        if let s = CGSessionCopyCurrentDictionary() as? [String: Any], (s["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        defer { IOObjectRelease(svc) }
        if let v = IORegistryEntryCreateCFProperty(svc, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
            return v.doubleValue / 1_000_000_000 > 300
        }
        return false
    }

    func testerIphone() {
        let a = iphoneActif; iphoneActif = true
        envoyerIphone("Test : les alertes de Claude arriveront ici quand tu seras loin du Mac.")
        iphoneActif = a
    }

    // ——— Alerte iPhone par iMessage (à soi-même) ———
    func envoyerIphone(_ texte: String) {
        guard iphoneActif, !iphone.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "on run argv", "-e", "tell application \"Messages\"", "-e", "set s to 1st account whose service type = iMessage",
                       "-e", "send (item 1 of argv) to participant (item 2 of argv) of s", "-e", "end tell", "-e", "end run", "EyeOn ✦ " + texte, iphone]
        let err = Pipe(); p.standardOutput = FileHandle.nullDevice; p.standardError = err
        p.terminationHandler = { pr in
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            try? "\(Date()) code=\(pr.terminationStatus) \(msg)".write(toFile: EyeOn.chemin("iphone.log"), atomically: true, encoding: .utf8)
        }
        try? p.run()
    }

    func microActif() -> Bool {
        var adr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var appareil = AudioDeviceID(0); var taille = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &adr, 0, nil, &taille, &appareil) == noErr, appareil != 0 else { return false }
        adr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        var actif: UInt32 = 0; taille = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(appareil, &adr, 0, nil, &taille, &actif) == noErr else { return false }
        return actif != 0
    }

    func majEveil(travaille: Bool) {
        let doit = eveil && travaille
        if doit && !assertionActive {
            assertionActive = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "Claude travaille encore" as CFString, &assertion) == kIOReturnSuccess
        } else if !doit && assertionActive {
            IOPMAssertionRelease(assertion); assertionActive = false
        }
    }

    // Détecte les fins : barre de progression terminée, ou Claude qui finit une demande d'au moins 1 min.
    func detecterFins(_ json: String) {
        guard let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        var fins: [String] = []
        for t in d["taches"] as? [[String: Any]] ?? [] {
            let cle = "\(t["titre"] ?? "")|\(t["debut"] ?? "")"
            if t["fin"] != nil, !tachesFinies.contains(cle) { tachesFinies.insert(cle); if !premierPassage { fins.append("\(t["titre"] ?? "Tâche") : terminé") } }
        }
        let s = (d["sessions"] as? [String: [String: Any]] ?? [:]).values.max { ($0["maj"] as? Double ?? 0) < ($1["maj"] as? Double ?? 0) }
        let statut = s?["statut"] as? String
        if statut == "travaille" {
            if debutTravail == nil { debutTravail = s?["depuis"] as? Double ?? Date().timeIntervalSince1970 }
            demandeEnCours = s?["demande"] as? String ?? demandeEnCours
        } else if let deb = debutTravail {
            debutTravail = nil
            if statut == "attend", Date().timeIntervalSince1970 - deb >= 60, !premierPassage {
                fins.append("Claude a fini : « \(demandeEnCours) »")
            }
        }
        premierPassage = false
        // Rappel « Claude t'attend » : une seule fois, 3 min après une question, ou 5 min après une longue demande.
        if statut == "attend", rappels, let dep = s?["attend_depuis"] as? Double, rappelPour != dep {
            let question = (s?["question"] as? Bool) == true
            let duree = dep - (s?["depuis"] as? Double ?? dep)
            let delai: Double = question ? 180 : 300
            if (question || duree >= 60) && Date().timeIntervalSince1970 - dep >= delai {
                rappelPour = dep
                if enAttente == nil { enAttente = ("Claude t'attend", question ? "Il t'a posé une question" : "« \(s?["demande"] as? String ?? "") »"); attenteDepuis = Date() }
            }
        }
        if notifs, let texte = fins.last { enAttente = ("✓ Tâche terminée", texte); attenteDepuis = Date() }
        livrerSiPossible()
    }

    func json2(_ t: String) -> String { (try? String(data: JSONSerialization.data(withJSONObject: [t]), encoding: .utf8))?.dropFirst().dropLast().description ?? "\"\"" }

    func pousser(_ w: WKWebView, _ json: String) {
        let fini = (try? String(data: JSONSerialization.data(withJSONObject: [messageFini ?? ""]), encoding: .utf8)) ?? "[\"\"]"
        let r = "maj(\(json), {flottante: \(flottante), coin: \(coin), notifs: \(notifs), compact: \(compact), dnd: \(nePasDeranger), rappels: \(rappels), iphone: \(!iphone.isEmpty), iphoneActif: \(iphoneActif), reglagesOuverts: \(reglagesOuverts), titreBulle: \(json2(titreBulle)), fini: \(fini)[0]})"
        w.evaluateJavaScript(r, completionHandler: nil)
    }

    func rafraichir() {
        DispatchQueue.global(qos: .utility).async {
            var objet = Lecteur.lire()
            objet["eveil"] = reglages.bool(forKey: "eveil")
            guard let data = try? JSONSerialization.data(withJSONObject: objet, options: [.withoutEscapingSlashes]),
                  let json = String(data: data, encoding: .utf8) else { return }
            EyeOn.creerDossier()
            ecrireJSON(objet, sortieWidget)   // lu par le widget de Bureau (sandbox, lecture seule)
            DispatchQueue.main.async {
                self.dernierJSON = json
                self.majEveil(travaille: self.estEnTravail(json))
                self.detecterFins(json)
                self.livrerSiPossible()
                if self.fenetre.isVisible { self.pousser(self.webFenetre, json) }
                if self.popover.isShown { self.pousser(self.webPopover, json) }
                self.rechargerWidget(json)
            }
        }
    }

    // Recharge le widget de Bureau quand l'état change vraiment (le système limite la fréquence).
    // Signal au widget du Bureau : immédiat quand une tâche commence/finit ou que l'état change,
    // à chaque nouvelle action (au plus toutes les 10 s), et toutes les 30 s pendant le travail.
    func rechargerWidget(_ json: String) {
        guard let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        let ss = (d["sessions"] as? [String: [String: Any]] ?? [:]).values
        let sessions = ss.map { "\($0["statut"] ?? "")" }.sorted().joined()
        let actions = ss.map { "\($0["action"] ?? "")" }.sorted().joined()
        // titre + état + palier de 10 % : un signal à chaque dizaine pour recaler l'anneau
        let taches = (d["taches"] as? [[String: Any]] ?? []).map { t -> String in
            let tot = t["total"] as? Double ?? 0, fait = t["fait"] as? Double ?? 0
            return "\(t["titre"] ?? "")\(t["fin"] != nil)\(t["bloque"] != nil)\(tot > 0 ? Int(fait / tot * 10) : 0)"
        }.joined()
        let agents = (d["agents"] as? [String: [String: Any]] ?? [:]).values.filter { "\($0["statut"] ?? "")" == "en cours" }.count
        let important = "\(sessions)|\(taches)|\(agents)|\(d["eveil"] ?? "")"
        let ecart = Date().timeIntervalSince(dernierRechargement)
        let travaille = sessions.contains("travaille")
        if important != derniereSignature || (actions != derniereAction && ecart > 10) || (travaille && ecart > 30) {
            derniereSignature = important; derniereAction = actions; dernierRechargement = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        if m.name == "hauteur", let h = m.body as? Double {
            if m.webView === webFenetre, abs(CGFloat(h) - hauteurFenetre) > 1 { hauteurFenetre = CGFloat(h); placer() }
            if m.webView === webPopover { popover.contentSize = NSSize(width: largeur, height: CGFloat(h)) }
        } else if m.name == "action", let a = m.body as? String {
            switch a {
            case "flottante": flottante.toggle(); flottante ? fenetre.orderFrontRegardless() : fenetre.orderOut(nil)
            case "coin": coin = (coin + 1) % 4; placer()
            case "widget": WidgetCenter.shared.reloadAllTimelines()
            case "eveil": basculerEveil()
            case "notifs": notifs.toggle()
            case "reglages-ouvert": reglagesOuverts = true; return
            case "reglages-ferme": reglagesOuverts = false; return
            case "dnd": nePasDeranger.toggle()
            case "rappels": rappels.toggle()
            case "iphone": iphoneActif.toggle()
            case "terminal": ouvrirTerminal()
            case "fichier": ouvrirDernierFichier(dossier: false)
            case "dossier": ouvrirDernierFichier(dossier: true)
            case "deplier": compact = false; fermeture?.invalidate(); popover.contentViewController?.view.window?.makeKey()
            case "preferences": popover.performClose(nil); Fenetres.reglages()
            case "quitter": NSApp.terminate(nil)
            default: break
            }
            if !dernierJSON.isEmpty { pousser(webPopover, dernierJSON) }
        }
    }

    func placer() {
        guard let ecran = NSScreen.main?.visibleFrame else { return }
        let marge: CGFloat = 16
        let x = (coin == 0 || coin == 2) ? ecran.maxX - largeur - marge : ecran.minX + marge
        let y = (coin < 2) ? ecran.maxY - hauteurFenetre - marge : ecran.minY + marge
        fenetre.setFrame(NSRect(x: x, y: y, width: largeur, height: hauteurFenetre), display: true, animate: fenetre.isVisible)
    }
}

// Ligne de commande (sans interface) : connexion / déconnexion des hooks, utile pour l'assistance et les tests.
//   EyeOn --connecter [settings.json]   EyeOn --deconnecter [settings.json]   EyeOn --statut [settings.json]
let args = CommandLine.arguments
if args.count >= 2, ["--connecter", "--deconnecter", "--statut"].contains(args[1]) {
    let fichier = args.count >= 3 ? args[2] : ConnexionClaude.fichierParDefaut
    do {
        switch args[1] {
        case "--connecter":
            let s = try ConnexionClaude.connecter(binaire: binaireHook, fichier: fichier)
            print("Connecté : \(fichier)" + (s.map { "\nSauvegarde : \($0)" } ?? ""))
        case "--deconnecter":
            let s = try ConnexionClaude.deconnecter(fichier: fichier)
            print(s == nil ? "Rien à retirer : \(fichier)" : "Déconnecté : \(fichier)\nSauvegarde : \(s!)")
        default:
            print(ConnexionClaude.estConnecte(fichier) ? "connecté" : "non connecté")
        }
        exit(0)
    } catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
}

let app = NSApplication.shared
let delegue = Appli()
app.delegate = delegue
app.run()
