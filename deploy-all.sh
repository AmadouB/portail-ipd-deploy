#!/bin/bash
# ══════════════════════════════════════════════════════════
#   PORTAIL IPD — Déploiement automatique sur SRV-SEID
#   Version 2026-04-25
#
#   Usage (en tant que root sur SRV-SEID) :
#     bash <(curl -fsSL https://raw.githubusercontent.com/AmadouB/portail-ipd-deploy/main/deploy-all.sh)
#
#   Idempotent : peut être ré-exécuté sans danger.
# ══════════════════════════════════════════════════════════

set -e

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}  ✓${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERREUR]${NC} $1"; exit 1; }

# Forcer root
if [ "$EUID" -ne 0 ]; then
  err "Ce script doit être exécuté en root (sudo bash deploy-all.sh ou être déjà root)"
fi

DEPLOY_URL="https://github.com/AmadouB/portail-ipd-deploy/raw/main/portail-ipd-deploy.tar.gz"
WORK_DIR="/home/bao"
PROJECT_DIR="${WORK_DIR}/portail-ipd"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  PORTAIL IPD — Déploiement SRV-SEID             ║${NC}"
echo -e "${CYAN}║  Cible: 10.1.7.247                              ║${NC}"
echo -e "${CYAN}║  $(date '+%Y-%m-%d %H:%M:%S')                          ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# ─── ÉTAPE 1: Outils de base ──────────────────────
info "ÉTAPE 1/7 : Vérification des outils de base"
MISSING=""
for tool in curl wget tar gzip; do
  command -v $tool >/dev/null 2>&1 || MISSING="$MISSING $tool"
done
if [ -n "$MISSING" ]; then
  apt update -qq
  apt install -y -qq curl wget ca-certificates gnupg tar gzip 2>&1 | tail -3
fi
ok "Outils de base : OK"

# ─── ÉTAPE 2: Docker ──────────────────────────────
info "ÉTAPE 2/7 : Docker"
if ! command -v docker >/dev/null 2>&1; then
  info "  Installation de Docker depuis le dépôt officiel..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt update -qq
  apt install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>&1 | tail -3
fi

systemctl enable docker >/dev/null 2>&1 || true
systemctl start docker >/dev/null 2>&1 || true

# Ajouter bao au groupe docker
if id bao >/dev/null 2>&1; then
  usermod -aG docker bao 2>/dev/null || true
fi

ok "Docker : $(docker --version | awk '{print $3}' | tr -d ',')"
ok "Compose : $(docker compose version --short 2>/dev/null || docker compose version | awk '{print $4}')"

# ─── ÉTAPE 3: Firewall ────────────────────────────
info "ÉTAPE 3/7 : Firewall"
if command -v ufw >/dev/null 2>&1; then
  ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ok "UFW : ports 22 et 80 ouverts"
else
  warn "UFW non installé (pas bloquant)"
fi

# ─── ÉTAPE 4: Téléchargement du paquet ────────────
info "ÉTAPE 4/7 : Téléchargement du paquet de déploiement"
cd "$WORK_DIR"
rm -f portail-ipd-deploy.tar.gz
wget -q --show-progress "$DEPLOY_URL" -O portail-ipd-deploy.tar.gz
ARCHIVE_SIZE=$(stat -c%s portail-ipd-deploy.tar.gz 2>/dev/null || echo "0")
if [ "$ARCHIVE_SIZE" -lt 100000 ]; then
  err "Archive trop petite ($ARCHIVE_SIZE octets) — téléchargement échoué"
fi
ok "Archive téléchargée : $(ls -lh portail-ipd-deploy.tar.gz | awk '{print $5}')"

# ─── ÉTAPE 5: Extraction ──────────────────────────
info "ÉTAPE 5/7 : Extraction"
# Sauvegarder ancienne version si elle existe
if [ -d "$PROJECT_DIR" ]; then
  warn "  Ancienne installation détectée — sauvegarde..."
  mv "$PROJECT_DIR" "${PROJECT_DIR}.backup-$(date +%Y%m%d-%H%M%S)"
fi
tar -xzf portail-ipd-deploy.tar.gz
chown -R bao:bao "$PROJECT_DIR"
chmod +x "$PROJECT_DIR/scripts/install-on-server.sh" "$PROJECT_DIR/docker-entrypoint.sh" 2>/dev/null || true
ok "Extrait dans $PROJECT_DIR"

# ─── ÉTAPE 6: Build + démarrage ───────────────────
info "ÉTAPE 6/7 : Build de l'image Docker (5-8 min, soyez patient)"
cd "$PROJECT_DIR"
cp -f .env.production .env

# Arrêter les anciens conteneurs s'ils existent
docker compose down 2>/dev/null || true

# Build
docker compose build --no-cache 2>&1 | tail -20

info "  Démarrage des conteneurs..."
docker compose up -d

info "  Attente du démarrage de PostgreSQL et de l'app (45s)..."
sleep 45

echo ""
docker compose ps

# ─── ÉTAPE 7: Seed ────────────────────────────────
info "ÉTAPE 7/7 : Chargement des utilisateurs initiaux"
sleep 5
SEED_OK=0
for attempt in 1 2 3; do
  if docker compose exec -T app sh -c "cd /app && node_modules/.bin/tsx prisma/seed.ts" 2>&1 | tail -10; then
    SEED_OK=1
    break
  fi
  warn "  Tentative seed $attempt échouée — nouvelle tentative dans 10s..."
  sleep 10
done

if [ $SEED_OK -eq 0 ]; then
  warn "Seed échoué — vous pourrez le relancer manuellement avec :"
  echo "  cd $PROJECT_DIR && docker compose exec app sh -c 'cd /app && node_modules/.bin/tsx prisma/seed.ts'"
fi

# ─── FINALISATION ─────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   ✓ DÉPLOIEMENT TERMINÉ                          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "10.1.7.247")

if curl -sf -o /dev/null -w "%{http_code}" http://localhost/ | grep -qE "^(200|301|302|307|308)$"; then
  echo -e "  ${GREEN}URL :${NC}     http://${SERVER_IP}"
else
  echo -e "  ${YELLOW}URL :${NC}     http://${SERVER_IP}  (peut nécessiter 30s de plus)"
fi

echo ""
echo "  Comptes initiaux :"
echo "    ibrahima.fall@pasteur.sn  →  IbrahimaIPD@2026  (admin)"
echo "    sophie.diallo@pasteur.sn  →  SophieIPD@2026    (admin)"
echo "    lamine.traore@pasteur.sn  →  LamineIPD@2026    (admin)"
echo "    fatoumata.niang@pasteur.sn →  FatouIPD@2026    (utilisateur)"
echo "    seid@pasteur.sn           →  SeidIPD@2026     (utilisateur)"
echo ""
echo "  Commandes utiles :"
echo -e "    ${CYAN}cd $PROJECT_DIR && docker compose ps${NC}        État"
echo -e "    ${CYAN}cd $PROJECT_DIR && docker compose logs -f${NC}   Logs en temps réel"
echo -e "    ${CYAN}cd $PROJECT_DIR && docker compose restart app${NC}  Redémarrer l'app"
echo ""
