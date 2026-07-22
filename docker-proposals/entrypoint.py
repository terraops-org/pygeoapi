#!/usr/bin/env python3
# =================================================================
#
# Shell-free entrypoint for the pygeoapi distroless image.
#
# Distroless images ship no shell, so docker/entrypoint.sh (bash)
# cannot run. This reproduces its default "run" behaviour: generate
# the OpenAPI (and best-effort AsyncAPI) documents, then exec
# gunicorn. Same ENV interface as docker/entrypoint.sh.
#
# =================================================================
import os
import subprocess
import sys

PYGEOAPI_HOME = "/pygeoapi"
VENV_BIN = "/venv/bin"


def env(name, default):
    """Return env var value, falling back to default when unset/empty."""
    value = os.environ.get(name)
    return value if value else default


def main():
    os.environ["PYGEOAPI_HOME"] = PYGEOAPI_HOME
    config = env("PYGEOAPI_CONFIG", f"{PYGEOAPI_HOME}/local.config.yml")
    openapi = env("PYGEOAPI_OPENAPI", f"{PYGEOAPI_HOME}/local.openapi.yml")
    asyncapi = env("PYGEOAPI_ASYNCAPI", f"{PYGEOAPI_HOME}/local.asyncapi.yml")
    os.environ["PYGEOAPI_CONFIG"] = config
    os.environ["PYGEOAPI_OPENAPI"] = openapi
    os.environ["PYGEOAPI_ASYNCAPI"] = asyncapi

    fail_on_invalid = env(
        "PYGEOAPI_OPENAPI_GENERATE_FAIL_ON_INVALID_COLLECTION", "true")
    fail_flag = ("--no-fail-on-invalid-collection"
                 if fail_on_invalid == "false"
                 else "--fail-on-invalid-collection")

    os.chdir(PYGEOAPI_HOME)
    pygeoapi = f"{VENV_BIN}/pygeoapi"

    print(f"START entrypoint.py (config={config})", flush=True)

    print("Generating openapi document", flush=True)
    subprocess.run(
        [pygeoapi, "openapi", "generate", config,
         "--output-file", openapi, fail_flag],
        check=True,
    )
    print("openapi document generated", flush=True)

    print("Generating asyncapi document (best effort)", flush=True)
    try:
        subprocess.run(
            [pygeoapi, "asyncapi", "generate", config,
             "--output-file", asyncapi],
            check=True,
        )
    except subprocess.CalledProcessError:
        print("asyncapi could not be generated; skipping", flush=True)

    # gunicorn settings — same defaults as docker/entrypoint.sh
    script_name = env("SCRIPT_NAME", "/")
    if script_name == "/":
        script_name = ""
    os.environ["SCRIPT_NAME"] = script_name

    host = env("CONTAINER_HOST", "0.0.0.0")
    port = env("CONTAINER_PORT", "80")
    name = env("CONTAINER_NAME", "pygeoapi")
    workers = env("WSGI_WORKERS", "4")
    timeout = env("WSGI_WORKER_TIMEOUT", "6000")
    worker_class = env("WSGI_WORKER_CLASS", "gevent")
    wsgi_app = env("WSGI_APP", "pygeoapi.flask_app:APP")

    argv = [
        "gunicorn",
        "--workers", workers,
        "--worker-class", worker_class,
        "--timeout", timeout,
        "--name", name,
        "--bind", f"{host}:{port}",
        wsgi_app,
    ]
    print(f"Starting gunicorn on {host}:{port} "
          f"({workers} workers, class={worker_class}, "
          f"SCRIPT_NAME='{script_name}')", flush=True)
    sys.stdout.flush()
    os.execv(f"{VENV_BIN}/gunicorn", argv)


if __name__ == "__main__":
    main()
