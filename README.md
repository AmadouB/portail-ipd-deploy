# Déploiement Portail IPD — SRV-SEID (10.1.7.247)

## Résumé
- **Cible** : SRV-SEID — Ubuntu 24.04.4 LTS
- **Accès** : JumpServer 10.99.1.10 → asset SRV-SEID
- **Utilisateur** : bao (mot de passe + MFA)
- **Stack déployée** : Nginx (80) + Next.js (3000) + PostgreSQL (5432)

## Étape 1 — Upload de l'archive

Dans JumpServer (http://10.99.1.10) :

1. Menu **File Manager**
2. Naviguer vers l'asset **SRV-SEID**
3. Uploader `portail-ipd-deploy.tar.gz` dans `/home/bao/` ou `/tmp/`

## Étape 2 — Session Luna sur SRV-SEID

Vous avez déjà une session active sur `bao@SRV-SEID`. Sinon :
- My assets → SRV-SEID → double-clic → session Luna ouverte

## Étape 3 — Installation

```bash
# Vérifier l'archive
ls -lh ~/portail-ipd-deploy.tar.gz    # ou /tmp/

# Extraction
cd ~
tar -xzf portail-ipd-deploy.tar.gz
cd portail-ipd

# Installation complète (installe Docker + déploie + démarre)
sudo ./scripts/install-on-server.sh
```

Durée : **5-8 min** (build de l'image + démarrage).

## Étape 4 — Chargement des données

```bash
sudo ./scripts/install-on-server.sh --seed
```

Crée les 5 comptes initiaux et 6 modules.

## Étape 5 — Accès

Une fois déployé, l'URL affichée est `http://10.1.7.247` (IP du SRV-SEID).
Accessible depuis n'importe quelle machine du réseau IPD connectée au VPN.

### Comptes initiaux

| Email | Rôle | Mot de passe |
|-------|------|--------------|
| ibrahima.fall@pasteur.sn | admin_general | IbrahimaIPD@2026 |
| sophie.diallo@pasteur.sn | admin_general | SophieIPD@2026 |
| lamine.traore@pasteur.sn | admin_general | LamineIPD@2026 |
| fatoumata.niang@pasteur.sn | utilisateur | FatouIPD@2026 |
| seid@pasteur.sn | utilisateur | SeidIPD@2026 |

## Commandes d'exploitation

| Commande | Usage |
|----------|-------|
| `sudo ./scripts/install-on-server.sh --status` | État des conteneurs + DB |
| `sudo ./scripts/install-on-server.sh --logs` | Logs temps réel |
| `sudo ./scripts/install-on-server.sh --update` | Rebuild + redémarrage |
| `sudo ./scripts/install-on-server.sh --stop` | Arrête les services |
| `docker compose ps` | État rapide |
| `docker compose logs app --tail=50` | Logs application |
| `docker compose exec postgres psql -U portail_ipd` | Accès DB directe |

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  SRV-SEID (10.1.7.247) — Ubuntu 24.04                │
│                                                      │
│  ┌──────────┐    ┌───────────┐    ┌─────────────┐   │
│  │  Nginx   │ →  │  Portail  │ →  │ PostgreSQL  │   │
│  │  :80     │    │  Next.js  │    │   :5432     │   │
│  │ (public) │    │  :3000    │    │ (interne)   │   │
│  └──────────┘    └───────────┘    └─────────────┘   │
│        ↑                                             │
│        │  Docker Compose (3 conteneurs)              │
└────────┼─────────────────────────────────────────────┘
         │
   Utilisateurs IPD via VPN
```

## Architecture SSO

Le portail IPD génère un **token SSO signé HMAC-SHA256** transmis en URL
à chaque iframe applicative. Les apps cibles :

- **HoshinFlow** (hoshinflow.vercel.app) — endpoint `/api/auth/sso`
- **DRO** (à venir)

Le secret `SSO_SECRET` doit être identique entre le portail et chaque app.
Valeur actuelle : `ipd-sso-shared-secret-2026-k8Xm2v` (dans `.env`).

## Mise à jour

Pour déployer une nouvelle version :

```bash
# Sur votre Mac
cd /Users/amadou/Documents/IPD/portail-ipd
# Modifier le code, tester localement...
./scripts/make-deploy-package.sh     # regénère portail-ipd-deploy.tar.gz

# Upload via File Manager JumpServer

# Sur SRV-SEID via Luna
cd ~
tar -xzf portail-ipd-deploy.tar.gz
cd portail-ipd
sudo ./scripts/install-on-server.sh --update
```

## Dépannage

### Le build échoue : "Prisma failed"
```bash
docker compose logs app --tail=100
# Souvent : DATABASE_URL manquante ou mauvaise
cat .env
```

### Le conteneur redémarre en boucle
```bash
docker compose logs app -f
# Chercher l'erreur de démarrage
```

### PostgreSQL ne démarre pas
```bash
docker compose logs postgres
docker volume ls | grep pgdata
# En dernier recours : docker compose down -v (⚠ vide la DB)
```

### Le port 80 est déjà pris
```bash
sudo lsof -i :80
# Arrêter le service qui l'utilise (apache2, nginx hôte, etc.)
sudo systemctl stop nginx apache2 2>/dev/null
```

### Regénérer le seed
```bash
docker compose exec -T postgres psql -U portail_ipd -c "TRUNCATE \"User\", \"Module\" CASCADE;"
sudo ./scripts/install-on-server.sh --seed
```
