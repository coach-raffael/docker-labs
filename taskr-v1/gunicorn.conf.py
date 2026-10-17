# gunicorn reads this file from the working directory when you run: gunicorn app:app
import os

bind = f"0.0.0.0:{os.environ.get('PORT', '8080')}"
# Load the app in the master process before forking workers. A startup error (for example
# "database unreachable") then stops the whole process with exit code 1 instead of
# restarting the worker forever. The number of workers comes from WEB_CONCURRENCY.
preload_app = True
# taskr logs every request itself; gunicorn only reports its own start and stop.
accesslog = None
errorlog = "-"
loglevel = os.environ.get("LOG_LEVEL", "info").lower()
# gunicorn 25.1 and newer open a control socket under $HOME/.gunicorn. The app does not use it,
# and a non-root user in a container usually has no writable home directory.
control_socket_disable = True
