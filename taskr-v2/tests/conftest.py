"""Test helpers for taskr 2.0.

The app configures itself from environment variables when the module is imported, so the
tests import a fresh copy of app.py per test with the environment they need.
Run from this directory or from the repository root: python -m pytest -q
PostgreSQL tests run only when TEST_DATABASE_URL points to a database you may use for tests.
"""

import importlib.util
import os
import pathlib
import sys

import pytest

APP_FILE = pathlib.Path(__file__).resolve().parent.parent / "app.py"
ENV_KEYS = ("DATABASE_URL", "DATABASE_URL_FILE", "TASKR_VERSION", "LOG_FORMAT", "LOG_LEVEL", "PORT")


def import_app(monkeypatch, **env):
    """Import app.py with exactly the given environment variables set."""
    for key in ENV_KEYS:
        monkeypatch.delenv(key, raising=False)
    for key, value in env.items():
        monkeypatch.setenv(key, value)
    name = f"taskr_v2_under_test_{id(monkeypatch)}"
    spec = importlib.util.spec_from_file_location(name, APP_FILE)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    finally:
        sys.modules.pop(name, None)
    return module


@pytest.fixture
def load_app(monkeypatch):
    """Fixture returning a loader: load_app(DATABASE_URL=..., LOG_FORMAT=...) -> module."""
    return lambda **env: import_app(monkeypatch, **env)


@pytest.fixture
def app_file():
    return APP_FILE


@pytest.fixture
def memory_app(load_app):
    return load_app()


@pytest.fixture
def client(memory_app):
    return memory_app.app.test_client()


@pytest.fixture
def test_database_url():
    url = os.environ.get("TEST_DATABASE_URL")
    if not url:
        pytest.skip("set TEST_DATABASE_URL to run the PostgreSQL tests")
    return url
