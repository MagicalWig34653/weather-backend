# weather-backend: Deploy-Branch

Automatisch aus `main` gespiegelt (Workflow `deploy-branch.yml`). Nie hier ändern; Änderungen nur auf `main`.
Enthält nur, was ein Docker-Swarm-Manager braucht: `deploy/swarm/*` und `.env.example`.

Installation (Voraussetzungen: git, docker, curl):

    git clone --depth 1 --branch deploy https://github.com/MagicalWig34653/weather-backend.git radar
    cd radar && deploy/swarm/setup.sh

Update: `deploy/swarm/update.sh --pull-scripts` (holt zuerst neue Skripte per `git pull --ff-only`, dann neues Image).
Die `.env` liegt im Ordner `radar/` und wird nie versioniert.

Dokumentation: https://magicalwig34653.github.io/weather-backend/
