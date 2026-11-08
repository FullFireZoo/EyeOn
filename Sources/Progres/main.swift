// eyeon-progres — barre de progression affichée par EyeOn (panneau + widget), utilisable depuis n'importe quel script.
//   eyeon-progres <id> "<titre>" <fait> <total> [détail]
//   eyeon-progres fin <id>
//   eyeon-progres demo          (barre de démonstration de 20 secondes)
import Foundation

func aide() -> Never {
    let t = """
    Utilisation :
      eyeon-progres <id> "<titre>" <fait> <total> [détail]   crée ou met à jour une barre
      eyeon-progres fin <id>                                 termine une barre
      eyeon-progres demo                                     barre de démonstration (20 s)
    Exemple : eyeon-progres export "Export des photos" 12 40 "IMG_0012.jpg"

    """
    FileHandle.standardError.write(Data(t.utf8))
    exit(2)
}

let a = Array(CommandLine.arguments.dropFirst())
if a.first == "fin" {
    guard a.count >= 2 else { aide() }
    exit(Progres.fin(id: a[1]) ? 0 : 1)
} else if a.first == "demo" {
    for i in 0...20 {
        Progres.maj(id: "demo-eyeon", titre: "Démonstration EyeOn", fait: Double(i), total: 20, detail: "Étape \(i) sur 20")
        if i < 20 { Thread.sleep(forTimeInterval: 1) }
    }
    exit(0)
} else if a.count >= 4, let fait = Double(a[2].replacingOccurrences(of: ",", with: ".")),
          let total = Double(a[3].replacingOccurrences(of: ",", with: ".")) {
    Progres.maj(id: a[0], titre: a[1], fait: fait, total: total, detail: a.count > 4 ? a[4] : "")
    exit(0)
} else { aide() }
