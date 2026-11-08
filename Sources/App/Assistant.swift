// Assistant de premier lancement et fenêtre Réglages d’EyeOn (SwiftUI).
import Cocoa
import SwiftUI
import ServiceManagement
import UserNotifications

// ——— Où se trouve l'app ? (les hooks doivent pointer vers un emplacement stable) ———
enum Emplacement {
    static var chemin: String { Bundle.main.bundlePath }
    /// Lancée depuis l'image disque ou depuis une copie temporaire de macOS (« App Translocation ») : pas définitif.
    static var estDefinitif: Bool { !chemin.hasPrefix("/Volumes/") && !chemin.contains("/AppTranslocation/") }
}

// ——— État partagé par l'assistant et les réglages ———
final class Modele: ObservableObject {
    @Published var connecte = ConnexionClaude.estConnecte()
    @Published var notifications: UNAuthorizationStatus = .notDetermined
    @Published var disqueComplet = Modele.accesDisque()
    @Published var ouvertureSession = SMAppService.mainApp.status == .enabled
    @Published var iphone = UserDefaults.standard.string(forKey: "iphone") ?? ""
    @Published var message: String? = nil
    @Published var erreur: String? = nil
    @Published var etape = 0

    static func accesDisque() -> Bool {
        // Le dossier de Concentration n'est lisible qu'avec l'Accès complet au disque
        let d = EyeOn.vraiHome() + "/Library/DoNotDisturb/DB"
        return (try? FileManager.default.contentsOfDirectory(atPath: d)) != nil
    }

    func actualiser() {
        connecte = ConnexionClaude.estConnecte()
        disqueComplet = Modele.accesDisque()
        ouvertureSession = SMAppService.mainApp.status == .enabled
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { self.notifications = s.authorizationStatus }
        }
    }

    func connecter() {
        erreur = nil
        guard Emplacement.estDefinitif else {
            erreur = "Glisse d'abord EyeOn dans le dossier Applications, puis rouvre-le depuis là."
            return
        }
        do {
            let s = try ConnexionClaude.connecter(binaire: binaireHook)
            message = "Connecté. Copie de sécurité de tes réglages : " + (s.map { ($0 as NSString).lastPathComponent } ?? "aucune (fichier créé)")
        } catch { erreur = error.localizedDescription }
        actualiser()
    }

    func deconnecter() {
        erreur = nil
        do {
            let s = try ConnexionClaude.deconnecter()
            message = s == nil ? "Rien à retirer." : "Déconnecté de Claude Code. Copie de sécurité : " + ((s! as NSString).lastPathComponent)
        } catch { erreur = error.localizedDescription }
        actualiser()
    }

    func demanderNotifications() {
        NSApp.activate(ignoringOtherApps: true)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            DispatchQueue.main.async { self.actualiser() }
        }
    }

    func ouvrirReglagesNotifications() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }

    func ouvrirAccesDisque() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func basculerOuvertureSession(_ oui: Bool) {
        erreur = nil
        do {
            if oui { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            erreur = "Ouverture de session : \(error.localizedDescription)"
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
        actualiser()
    }

    func enregistrerIphone() {
        let v = iphone.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(v, forKey: "iphone")
        if !v.isEmpty { UserDefaults.standard.set(true, forKey: "iphoneActif") }
    }

    func testerIphone() {
        enregistrerIphone()
        (NSApp.delegate as? Appli)?.testerIphone()
        message = "Message de test envoyé via Messages (macOS peut te demander l'autorisation la première fois)."
    }

    /// Désinstallation : retire les hooks, l'ouverture de session et (au choix) les données, puis quitte.
    func desinstaller() {
        let a = NSAlert()
        a.messageText = "Désinstaller EyeOn ?"
        a.informativeText = "Les hooks EyeOn seront retirés de Claude Code (tes autres réglages restent intacts) et l'ouverture automatique sera désactivée. Tu pourras ensuite mettre l'app à la corbeille."
        a.addButton(withTitle: "Désinstaller"); a.addButton(withTitle: "Annuler")
        let effacer = NSButton(checkboxWithTitle: "Effacer aussi les données d’EyeOn", target: nil, action: nil)
        effacer.state = .on; a.accessoryView = effacer
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do { try ConnexionClaude.deconnecter() } catch {
            erreur = error.localizedDescription; return
        }
        try? SMAppService.mainApp.unregister()
        if effacer.state == .on { try? FileManager.default.removeItem(atPath: EyeOn.dossier) }
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "fr.fullfirezoo.eyeon")
        let fin = NSAlert()
        fin.messageText = "EyeOn est désinstallé"
        fin.informativeText = "Tu peux maintenant mettre EyeOn à la corbeille (dossier Applications). Pense aussi à retirer le widget du Bureau s'il y est."
        fin.runModal()
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Emplacement.chemin)])
        NSApp.terminate(nil)
    }
}

// ——— Briques visuelles ———
struct Logo: View {
    var taille: CGFloat = 64
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: taille * 0.09)
            Circle().trim(from: 0, to: 0.75)
                .stroke(LinearGradient(colors: [Color(red: 0.35, green: 0.78, blue: 0.98), Color(red: 0.04, green: 0.52, blue: 1)], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: taille * 0.09, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "sparkle").font(.system(size: taille * 0.38, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.7, blue: 0.48), Color(red: 0.91, green: 0.4, blue: 0.24)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .frame(width: taille, height: taille)
    }
}

struct LigneEtat: View {
    let symbole: String; let titre: String; let detail: String
    var ok: Bool? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbole).font(.system(size: 18)).foregroundStyle(.tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(titre).font(.system(size: 13, weight: .semibold))
                    if let ok { Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? Color.green : Color.secondary) }
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

struct Messages: View {
    @ObservedObject var m: Modele
    var body: some View {
        if let e = m.erreur { Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange) }
        else if let t = m.message { Label(t, systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(.secondary) }
    }
}

// ——— Assistant de premier lancement ———
struct VueAssistant: View {
    @ObservedObject var m: Modele
    var etape: Int { get { m.etape } nonmutating set { m.etape = newValue } }
    var fermer: () -> Void
    let total = 5

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch etape {
                case 0: bienvenue
                case 1: connexion
                case 2: autorisations
                case 3: options
                default: termine
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 36).padding(.top, 30)
            Divider()
            HStack {
                HStack(spacing: 6) { ForEach(0..<total, id: \.self) { i in Circle().fill(i == etape ? Color.accentColor : Color.primary.opacity(0.15)).frame(width: 6, height: 6) } }
                Spacer()
                if etape > 0 && etape < total - 1 { Button("Retour") { m.message = nil; m.erreur = nil; etape -= 1 } }
                if etape < total - 1 {
                    Button(etape == 0 ? "Commencer" : (etape == 1 && !m.connecte ? "Plus tard" : "Continuer")) { m.message = nil; m.erreur = nil; etape += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Terminer") { UserDefaults.standard.set(true, forKey: "assistantTermine"); fermer() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 560, height: 470)
        .onAppear { m.actualiser() }
    }

    var bienvenue: some View {
        VStack(spacing: 14) {
            Logo(taille: 84).padding(.bottom, 6)
            Text("Bienvenue dans EyeOn").font(.system(size: 26, weight: .bold))
            Text("Suis en direct ce que fait Claude Code, sans quitter ce que tu fais.")
                .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 12) {
                LigneEtat(symbole: "menubar.rectangle", titre: "Dans la barre des menus", detail: "L'icône ✦ ouvre la progression, les étapes, les agents et le résumé du jour.")
                LigneEtat(symbole: "circle.circle", titre: "Sur ton Bureau", detail: "Un widget avec des anneaux de progression, comme les anneaux Activité.")
                LigneEtat(symbole: "bell.badge", titre: "Au bon moment", detail: "Une alerte quand une longue tâche est finie, discrète pendant une dictée ou une vidéo.")
                LigneEtat(symbole: "lock.shield", titre: "Tout reste sur ton Mac", detail: "Aucune donnée n'est envoyée nulle part.")
            }.padding(.top, 10)
        }
    }

    var connexion: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connecter à Claude Code").font(.system(size: 22, weight: .bold))
            Text("EyeOn ajoute de petits « hooks » à Claude Code : à chaque étape, Claude Code prévient EyeOn, qui met l'affichage à jour. Une copie de sécurité de tes réglages Claude Code est faite avant, et tes autres réglages ne sont pas touchés.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LigneEtat(symbole: "link", titre: m.connecte ? "Connecté à Claude Code" : "Pas encore connecté",
                      detail: "Fichier modifié : ~/.claude/settings.json", ok: m.connecte)
            if !Emplacement.estDefinitif {
                Label("Glisse d'abord EyeOn dans le dossier Applications, puis rouvre-le depuis là (sinon la connexion pointerait vers un emplacement temporaire).", systemImage: "arrow.down.app")
                    .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(m.connecte ? "Reconnecter" : "Connecter à Claude Code") { m.connecter() }
                    .controlSize(.large).buttonStyle(.borderedProminent).disabled(!Emplacement.estDefinitif)
            }
            Messages(m: m)
            Text("Les sessions de Claude Code déjà ouvertes prendront en compte EyeOn à leur prochain redémarrage.")
                .font(.system(size: 11.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    var autorisations: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Autorisations").font(.system(size: 22, weight: .bold))
            VStack(alignment: .leading, spacing: 8) {
                LigneEtat(symbole: "bell", titre: "Notifications", detail: "Pour te prévenir quand une tâche est finie ou quand Claude t'attend.", ok: m.notifications == .authorized || m.notifications == .provisional)
                HStack {
                    Button("Autoriser les notifications") { m.demanderNotifications() }.disabled(m.notifications != .notDetermined)
                    if m.notifications == .denied { Button("Ouvrir les Réglages") { m.ouvrirReglagesNotifications() } }
                }.padding(.leading, 38)
            }
            VStack(alignment: .leading, spacing: 8) {
                LigneEtat(symbole: "moon", titre: "Accès complet au disque (facultatif)", detail: "Uniquement pour savoir si Ne pas déranger ou une Concentration est active, et rester discret dans ce cas. Ajoute EyeOn dans la liste qui s'ouvre, puis reviens ici.", ok: m.disqueComplet)
                HStack {
                    Button("Ouvrir les Réglages") { m.ouvrirAccesDisque() }
                    Button("Vérifier") { m.actualiser() }
                }.padding(.leading, 38)
            }
            Spacer(minLength: 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in m.actualiser() }
    }

    var options: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Options").font(.system(size: 22, weight: .bold))
            VStack(alignment: .leading, spacing: 8) {
                LigneEtat(symbole: "iphone", titre: "Alerte sur iPhone (facultatif)", detail: "Si tu n'es pas devant ton Mac quand une tâche finit, EyeOn t'envoie un iMessage (à toi-même) via l'app Messages.")
                HStack {
                    TextField("Ton numéro ou ton adresse iMessage", text: $m.iphone).textFieldStyle(.roundedBorder).frame(width: 260)
                        .onSubmit { m.enregistrerIphone() }
                    Button("Tester") { m.testerIphone() }.disabled(m.iphone.trimmingCharacters(in: .whitespaces).isEmpty)
                }.padding(.leading, 38)
            }
            VStack(alignment: .leading, spacing: 8) {
                LigneEtat(symbole: "power", titre: "Ouvrir à l'ouverture de session", detail: "Pour que EyeOn soit toujours prêt quand tu lances Claude Code.")
                Toggle("Ouvrir EyeOn automatiquement", isOn: Binding(get: { m.ouvertureSession }, set: { m.basculerOuvertureSession($0) }))
                    .toggleStyle(.switch).padding(.leading, 38)
            }
            Messages(m: m)
            Spacer(minLength: 0)
        }
        .onDisappear { m.enregistrerIphone() }
    }

    var termine: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(.green).padding(.bottom, 4)
            Text("C'est prêt").font(.system(size: 26, weight: .bold))
            VStack(alignment: .leading, spacing: 12) {
                LigneEtat(symbole: "keyboard", titre: "⌥ Espace", detail: "Ouvre le panneau EyeOn depuis n'importe où.")
                LigneEtat(symbole: "rectangle.on.rectangle", titre: "Ajouter le widget", detail: "Clic droit sur le Bureau → Modifier les widgets → cherche « EyeOn ».")
                LigneEtat(symbole: "gearshape", titre: "Réglages", detail: "Dans le panneau ✦ → Réglages → Réglages d’EyeOn… (connexion, autorisations, désinstallation).")
                LigneEtat(symbole: "chart.bar", titre: "Barres pour tes scripts", detail: "eyeon-progres <id> \"<titre>\" <fait> <total> — voir le README.")
            }.padding(.top, 8)
        }
    }
}

// ——— Fenêtre Réglages ———
struct VueReglages: View {
    @ObservedObject var m: Modele
    var body: some View {
        Form {
            Section("Claude Code") {
                LabeledContent("Connexion") {
                    HStack(spacing: 6) {
                        Image(systemName: m.connecte ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(m.connecte ? .green : .secondary)
                        Text(m.connecte ? "Connecté" : "Non connecté")
                    }
                }
                HStack {
                    if m.connecte { Button("Déconnecter de Claude Code") { m.deconnecter() } }
                    else { Button("Connecter à Claude Code") { m.connecter() }.disabled(!Emplacement.estDefinitif) }
                }
            }
            Section("Autorisations") {
                LabeledContent("Notifications") {
                    if m.notifications == .notDetermined { Button("Autoriser") { m.demanderNotifications() } }
                    else { Button(m.notifications == .denied ? "Refusées — ouvrir les Réglages" : "Autorisées — Réglages") { m.ouvrirReglagesNotifications() } }
                }
                LabeledContent("Accès complet au disque") {
                    Button(m.disqueComplet ? "Activé — Réglages" : "Facultatif — ouvrir les Réglages") { m.ouvrirAccesDisque() }
                }
                Text("L'accès complet au disque sert uniquement à suivre Ne pas déranger / Concentration.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Alerte iPhone") {
                TextField("Numéro ou adresse iMessage", text: $m.iphone).onSubmit { m.enregistrerIphone() }
                HStack {
                    Button("Enregistrer") { m.enregistrerIphone(); m.message = "Enregistré." }
                    Button("Tester") { m.testerIphone() }.disabled(m.iphone.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("Démarrage") {
                Toggle("Ouvrir EyeOn à l'ouverture de session", isOn: Binding(get: { m.ouvertureSession }, set: { m.basculerOuvertureSession($0) }))
                Text("Raccourci : ⌥ Espace ouvre le panneau.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Revoir l'assistant…") { Fenetres.assistant() }
                    Spacer()
                    Button("Désinstaller…", role: .destructive) { m.desinstaller() }
                }
                Messages(m: m)
            } footer: {
                Text("EyeOn \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · tout reste en local sur ce Mac.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .onAppear { m.message = nil; m.erreur = nil; m.actualiser() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in m.actualiser() }
    }
}

// ——— Ouverture des fenêtres ———
enum Fenetres {
    static let modele = Modele()
    static var fAssistant: NSWindow?
    static var fReglages: NSWindow?

    static func fenetre(_ titre: String, _ vue: some View) -> NSWindow {
        let w = NSWindow(contentViewController: NSHostingController(rootView: vue))
        w.title = titre
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }

    static func assistant() {
        if fAssistant == nil {
            modele.etape = 0; fAssistant = fenetre("Bienvenue dans EyeOn", VueAssistant(m: modele, fermer: { fAssistant?.close() }))
            fAssistant?.titlebarAppearsTransparent = true
        }
        NSApp.activate(ignoringOtherApps: true)
        fAssistant?.makeKeyAndOrderFront(nil)
    }

    static func reglages() {
        if fReglages == nil { fReglages = fenetre("Réglages d’EyeOn", VueReglages(m: modele)) }
        NSApp.activate(ignoringOtherApps: true)
        fReglages?.makeKeyAndOrderFront(nil)
    }
}
