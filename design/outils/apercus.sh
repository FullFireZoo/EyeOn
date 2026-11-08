#!/bin/bash
# Produit des aperçus PNG de la mascotte, hors interface (sans lancer l'app) :
#   • le widget en veille (petit, moyen, grand ; clair et sombre) via ImageRenderer ;
#   • le panneau de la barre des menus (veille, travail, instant du réveil) via Chrome sans fenêtre.
# Usage : design/outils/apercus.sh   → PNG dans design/captures/ (dossier ignoré par git)
set -euo pipefail
D="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$D/design/captures"; mkdir -p "$OUT"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

echo "▸ Widget (ImageRenderer)"
sed 's/^@main$//' "$D/Sources/Widget/EyeOnWidget.swift" > "$TMP/widget.swift"   # le point d'entrée est celui du programme de rendu
swiftc -parse-as-library -framework WidgetKit -framework SwiftUI "$TMP/widget.swift" "$D/design/outils/rendu-widget.swift" -o "$TMP/rendu"
"$TMP/rendu" "$OUT"

echo "▸ Panneau (Chrome sans fenêtre)"
MAINTENANT=$(date +%s)
# Données d'exemple au format de widget.json
VEILLE="{now:$MAINTENANT, eveil:false, taches:[], agents:{}, journee:{secondes:9000, demandes:7, nb_taches:2},
  memoire:{pourcent:42, utilise:84000, fenetre:200000, compressions_jour:0},
  sessions:{x:{statut:'repos', maj:$((MAINTENANT-4320)), historique:[{a:'Widget mis à jour'},{a:'Relevé des prix terminé'},{a:'Fin'}]}}}"
TRAVAIL="{now:$MAINTENANT, eveil:true, journee:{secondes:9000, demandes:8, nb_taches:2}, dernier_fichier:'src/app.js',
  memoire:{pourcent:42, utilise:84000, fenetre:200000, compressions_jour:0},
  taches:[{titre:'Conversion des images', fait:12, total:40, debut:$((MAINTENANT-90)), detail:'photo-12.jpg'}],
  agents:{a:{desc:'Recherche dans le code', statut:'en cours', debut:$((MAINTENANT-40))}},
  sessions:{x:{statut:'travaille', maj:$MAINTENANT, depuis:$((MAINTENANT-150)), demande:'Ajoute la mascotte au panneau',
    action:'Modifie panneau.html', historique:[{a:'Lit README.md'},{a:'Lance build.sh'},{a:'Fin'}]}}}"
R="{compact:false, notifs:true, dnd:false, rappels:true, iphone:false, flottante:false, coin:0, reglagesOuverts:false, titreBulle:null, fini:null}"
# Chrome sans fenêtre impose une largeur minimale de fenêtre : la page est rendue plus large, le panneau fixé à 340 px, puis recadré.
# page <nom> <script> : copie du panneau + données injectées ; fond sombre comme le panneau réel
page() {
  local js="${2//$'\n'/ }"   # sed n'accepte pas de retour à la ligne dans le remplacement
  sed "s|</body>|<script>document.documentElement.style.background='#2a292d';document.body.style.width='340px';$js</script></body>|" "$D/Resources/panneau.html" > "$TMP/$1.html"
}
page veille "maj($VEILLE, $R);"
page travail "maj($TRAVAIL, $R);"
page reveil "maj($VEILLE, $R); setTimeout(() => maj($TRAVAIL, $R), 600);"
capture() {   # capture <nom> <page> <hauteur> <temps virtuel en ms>
  rm -f "$OUT/$1.png"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --window-size=600,"$3" \
    --virtual-time-budget="$4" --screenshot="$OUT/$1.png" "file://$TMP/$2.html?mode=popover" >/dev/null 2>&1
  # Chrome peut rendre la main avant d'avoir fini d'écrire l'image : on attend qu'elle soit complète
  for _ in $(seq 50); do [ -s "$OUT/$1.png" ] && sips -g pixelWidth "$OUT/$1.png" >/dev/null 2>&1 && break; perl -e 'select(undef,undef,undef,0.1)'; done
  # recadrage à 340 px de large (sips centre le recadrage si le décalage vaut 0 0, d’où « 1 0 »)
  sips -c $(( $3 * 2 )) 680 --cropOffset 1 0 "$OUT/$1.png" >/dev/null
  echo "✓ $1.png"
}
capture panneau-veille veille 470 1500
capture panneau-travail travail 520 1500
capture panneau-travail-b travail 520 1830
capture panneau-reveil-sursaut reveil 520 1550
