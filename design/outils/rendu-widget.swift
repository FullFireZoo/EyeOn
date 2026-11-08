// Rend le widget en veille en PNG, hors interface (ImageRenderer), pour vérifier le dessin sans installer l'app.
// Compilé avec une copie de Sources/Widget/EyeOnWidget.swift dont on retire @main (voir apercus.sh).
// Les Link et ProgressView(timerInterval:) s'affichent en carrés jaunes dans ImageRenderer : c'est normal.
import SwiftUI
import WidgetKit

@main
struct RenduWidget {
    @MainActor static func main() {
        let sortie = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        let maintenant = Date().timeIntervalSince1970
        // Données d'exemple : dernière activité il y a 1 h 12 → état « veille »
        let json = """
        {"now": \(maintenant), "taches": [], "sessions": {"exemple": {"statut": "repos", "maj": \(maintenant - 4320),
          "historique": [{"t": \(maintenant - 4900), "a": "Widget mis à jour"}, {"t": \(maintenant - 4400), "a": "Relevé des prix terminé"},
                         {"t": \(maintenant - 4320), "a": "Fin de session"}]}}}
        """
        let d = try! JSONDecoder().decode(Donnees.self, from: Data(json.utf8))
        let et = Etat(d)
        precondition(et.veille, "les données d'exemple devraient donner l'état veille")
        let tailles: [(String, WidgetFamily, CGSize)] = [("petit", .systemSmall, CGSize(width: 170, height: 170)),
                                                         ("moyen", .systemMedium, CGSize(width: 344, height: 164)),
                                                         ("grand", .systemLarge, CGSize(width: 344, height: 344))]
        func carte(_ f: WidgetFamily, _ t: CGSize, _ phase: Int, _ m: ColorScheme) -> some View {
            Veille(et: et, phase: phase, famille: f)
                .foregroundStyle(.primary)
                .padding(16)
                .frame(width: t.width, height: t.height)
                .background(Nacre())
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(14)
                .background(m == .dark ? Color(red: 0.14, green: 0.12, blue: 0.22) : Color(red: 0.78, green: 0.80, blue: 0.92))
                .environment(\.colorScheme, m)
        }
        func ecrire<V: View>(_ v: V, _ nom: String) {
            let r = ImageRenderer(content: v); r.scale = 2
            guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { print("échec : \(nom)"); return }
            try! png.write(to: URL(fileURLWithPath: sortie + "/" + nom))
            print("✓ \(nom)")
        }
        for (m, nomMode) in [(ColorScheme.light, "clair"), (.dark, "sombre")] {
            for (nom, f, t) in tailles { ecrire(carte(f, t, 0, m), "widget-veille-\(nom)-\(nomMode).png") }
            // planche des 8 images de la boucle (petit format) : respiration + montée des bulles
            ecrire(HStack(spacing: 0) { ForEach(0..<phasesVeille, id: \.self) { carte(.systemSmall, tailles[0].2, $0, m) } },
                   "widget-veille-boucle-\(nomMode).png")
        }
    }
}
