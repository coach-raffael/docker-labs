# docker-labs

Lab files for the course "Docker from First Container to Production" in the IT made simple community.

Course community: https://www.skool.com/coach-raffael-it-made-simple-5657

The course builds one application, **taskr**, over five days: a small task API in Python (Flask and
gunicorn) that stores its tasks in memory on Day 1 and in PostgreSQL from Day 2 on. You write every
Dockerfile, Compose file and stack file yourself. This repository gives you the application code,
the deliberately broken files, the swarm helper and the acceptance checks for the lab lessons.

## Layout

```
docker-labs
├── taskr-v1        # Day 1 (Modules 00-04): taskr 1.0, tasks in memory; you write the Dockerfile
├── taskr-v2        # Days 2-5 (Modules 06-18): taskr 2.0, PostgreSQL backend, DATABASE_URL_FILE
├── taskr-broken    # Day 2 (Module 07): source of the reference image taskr:broken, for your diagnosis
├── broken
│   ├── day3        # Module 11: compose-race.yaml (start-up race), Module 12: compose.yaml (three mistakes)
│   ├── day4        # Module 15: compose.yaml that runs but is not safe
│   └── day5        # Module 18: stack.yaml that Compose accepts and Swarm rejects (four mistakes)
├── swarm           # Day 5 (Modules 16-18): workers.sh starts the two Docker-in-Docker worker nodes
├── checks          # day1.sh to day5.sh: acceptance checks for the lab lessons, day2-break.sh plants a fault
└── .devcontainer   # GitHub Codespaces: Ubuntu 24.04 with Docker Engine (Docker-in-Docker feature)
```

## Usage

On your lab machine (Module 00 sets it up):

```
mkdir -p ~/labs && cd ~/labs
git clone https://github.com/coach-raffael/docker-labs.git
cd docker-labs
```

Every file holds the state the course expects when a module first uses it. Files you are asked to
write in a module (Dockerfiles, `compose.yaml`, `stack.yaml`, `.env`, `.dockerignore`) are not
prefilled. The reference images `quay.io/coach-raffael/taskr:1.0`, `2.0`, `2.1`, `2.2`, `2.3` and `broken`
are public: the course uses `1.0` and `broken` directly and the others only as a fallback when your own build fails.

### taskr

| Endpoint | Purpose |
| --- | --- |
| `GET /health` | status, version, storage (`memory` or `postgresql`); 503 when the database is gone |
| `GET /tasks` | all tasks, newest first; filter with `?status=open`, `in_progress` or `done` |
| `POST /tasks` | create a task: JSON `{"title": "...", "priority": "normal"}` (low, normal or high), answers 201 |
| `PATCH /tasks/<id>` | change the status: JSON `{"status": "done"}` (open, in_progress or done) |
| `GET /stats` | count per status, storage, hostname of the instance |

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `8080` | port gunicorn listens on |
| `LOG_LEVEL` | `INFO` | `DEBUG`, `INFO`, `WARNING` or `ERROR` |
| `LOG_FORMAT` | `text` | `text` or `json`, one line per request on stdout |
| `TASKR_VERSION` | `1.0.0` / `2.0.0` | version shown by `/health`; the Dockerfiles of Day 3 and later set it |
| `DATABASE_URL` | empty | taskr 2.0: `postgresql://user:password@host:5432/db`; empty means memory |
| `DATABASE_URL_FILE` | empty | taskr 2.0: path of a file with the URL, for swarm secrets (Module 17) |
| `WEB_CONCURRENCY` | gunicorn default (1) | number of gunicorn workers |

taskr 2.0 stops with exit code 1 and a clear message when the database is unreachable at start, when
`DATABASE_URL_FILE` does not exist, or when both variables are set. While it runs, a lost database
turns `/health` into a 503. Each container starts with `gunicorn app:app`; `gunicorn.conf.py` next
to `app.py` reads `PORT` and `LOG_LEVEL`.

Run the tests without containers (Python 3.12 or newer):

```
cd taskr-v2
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt pytest
python -m pytest -q
```

The PostgreSQL tests run when `TEST_DATABASE_URL` points to a database you may use for tests.

### Checks

Each lab lesson ends with `./checks/dayN.sh` from the repository root. The script prints one line
per acceptance criterion and `PASS` or `FAIL` at the end. Read a failing line as a hint, not as the
solution: the course workbook holds the full solution of every lab.

### Passwords in this repository

The PostgreSQL password `taskr-lab` and the user `taskr` in the broken files are training values for
your lab machine. Replace them with your own values when you move anything out of the lab.

## License

The code in this repository is licensed under the MIT License, see LICENSE.
The course text and workbooks are not part of this repository.

Author: Raffael Hühnerschulte
