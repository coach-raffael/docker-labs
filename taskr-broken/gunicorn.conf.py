# gunicorn reads this file from the working directory when you run: gunicorn app:app
import os

bind = f"127.0.0.1:{os.environ.get('PORT', '8080')}"
# Load the app in the master process before forking workers. A startup error then stops the
# whole process with the app's exit code instead of restarting the worker forever.
# The number of workers comes from WEB_CONCURRENCY.
preload_app = True
# taskr logs every request itself; gunicorn only reports its own start and stop.
accesslog = None
errorlog = "-"
loglevel = os.environ.get("LOG_LEVEL", "info").lower()
# gunicorn 25.1 and newer open a control socket under $HOME/.gunicorn. The app does not use it,
# and a non-root user in a container usually has no writable home directory.
control_socket_disable = True
