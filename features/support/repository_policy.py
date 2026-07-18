import json
import os
import selectors
import stat
import subprocess
import tempfile
from pathlib import Path


class RepositoryPolicy:
    def __init__(self, root: Path):
        self.root = root

    def load(self):
        self.readme = (self.root / "README.md").read_text()
        self.entrypoint = (self.root / "csb/entrypoint.sh").read_text()
        self.containerfile = (self.root / "csb/Containerfile").read_text()
        self.policy = (self.root / "csb/policy.yaml").read_text()
        install_policy = self.root / "csb/openclaw-install-policy"
        self.install_policy = install_policy.read_text() if install_policy.exists() else ""
        self.configure_script = self.root / "csb/configure-openclaw.mjs"

    def _run_config(self, extra_env=None, initial_config=None, env_text=None):
        temp_dir = tempfile.TemporaryDirectory()
        config_dir = Path(temp_dir.name)
        config_path = config_dir / "openclaw.json"
        if initial_config is not None:
            config_path.write_text(initial_config)
            os.link(config_path, config_dir / "prior-openclaw.json")
        if env_text is not None:
            (config_dir / ".env").write_text(env_text)

        env = {key: os.environ[key] for key in ("PATH", "SYSTEMROOT", "PATHEXT") if key in os.environ}
        env["OPENCLAW_STATE_DIR"] = str(config_dir)
        env["OPENCLAW_CONFIG_PATH"] = str(config_path)
        env["OPENCLAW_WORKSPACE_DIR"] = str(config_dir / "workspace")
        env.update(extra_env or {})

        try:
            result = subprocess.run(
                ["node", str(self.configure_script)],
                capture_output=True,
                text=True,
                env=env,
                timeout=10,
                check=False,
            )
        except BaseException:
            temp_dir.cleanup()
            raise
        return temp_dir, config_dir, config_path, result

    def _valid_config(self, extra_env=None, initial_config=None, env_text=None):
        env = {
            "OPENCLAW_GATEWAY_TOKEN": "fresh-token",
            "OPENCLAW_ALLOWED_SKILLS": '["team-prs"]',
        }
        env.update(extra_env or {})
        return self._run_config(env, initial_config, env_text)

    def assert_exec_requires_approval(self):
        temp, _, config_path, result = self._valid_config()
        try:
            assert result.returncode == 0, result.stderr
            config = json.loads(config_path.read_text())
            assert config["tools"]["exec"]["mode"] == "ask"
            assert config["tools"]["elevated"]["enabled"] is False
        finally:
            temp.cleanup()

    def assert_skill_visibility_is_explicit(self):
        temp, _, config_path, result = self._valid_config()
        try:
            assert result.returncode == 0, result.stderr
            config = json.loads(config_path.read_text())
            assert config["agents"]["defaults"]["skills"] == ["team-prs"]
        finally:
            temp.cleanup()

        temp, _, config_path, result = self._valid_config(
            {"OPENCLAW_ALLOWED_SKILLS": "[]"}
        )
        try:
            assert result.returncode == 0, result.stderr
            config = json.loads(config_path.read_text())
            assert config["agents"]["defaults"]["skills"] == []
        finally:
            temp.cleanup()

    def assert_runtime_installs_fail_closed(self):
        result = subprocess.run(
            [str(self.root / "csb/openclaw-install-policy")],
            input='{"target":"skill"}',
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        response = json.loads(result.stdout)
        assert result.returncode == 0
        assert response["protocolVersion"] == 1
        assert response["decision"] == "block"
        assert "runtime skill and plugin installation" in response["reason"]
        assert "COPY csb/openclaw-install-policy /usr/local/bin/openclaw-install-policy" in self.containerfile

        temp, _, config_path, config_result = self._valid_config()
        try:
            assert config_result.returncode == 0, config_result.stderr
            config = json.loads(config_path.read_text())
            policy = config["security"]["installPolicy"]
            assert policy["targets"] == ["skill", "plugin"]
            assert policy["exec"]["command"] == "/usr/local/bin/openclaw-install-policy"
        finally:
            temp.cleanup()

    def assert_missing_token_fails_closed(self):
        initial = '{"gateway":{"auth":{"token":"stale-token"}}}\n'
        temp, _, config_path, result = self._run_config(initial_config=initial)
        try:
            assert result.returncode != 0
            assert "OPENCLAW_GATEWAY_TOKEN is required" in result.stderr
            assert config_path.read_text() == initial
        finally:
            temp.cleanup()

    def assert_invalid_inputs_preserve_config(self):
        invalid_environments = [
            ({"OPENCLAW_PUBLIC_URL": "https://openclaw.example/path"}, "OPENCLAW_PUBLIC_URL"),
            ({"OPENCLAW_PUBLIC_URL": "https://user:secret@openclaw.example"}, "OPENCLAW_PUBLIC_URL"),
            ({"OPENCLAW_PROVIDERS": "[]"}, "OPENCLAW_PROVIDERS"),
            ({
                "OPENCLAW_PROVIDERS": json.dumps(
                    {"openai": {"api": "openai-responses", "baseUrl": "not-a-url"}}
                )
            }, "baseUrl"),
            ({
                "OPENCLAW_PROVIDERS": json.dumps(
                    {"openai": {"api": "openai-responses", "baseUrl": "https://api.openai.com", "apiKey": 7}}
                )
            }, "apiKey"),
            ({
                "OPENCLAW_PROVIDERS": json.dumps(
                    {"constructor": {"api": "openai-responses", "baseUrl": "https://api.openai.com"}}
                )
            }, "name"),
        ]
        for invalid_env, expected_error in invalid_environments:
            initial = '{"sentinel":"last-valid"}\n'
            temp, config_dir, config_path, result = self._valid_config(
                invalid_env, initial_config=initial
            )
            try:
                assert result.returncode != 0, invalid_env
                assert expected_error in result.stderr
                assert config_path.read_text() == initial
                assert list(config_dir.glob(".openclaw.json.*.tmp")) == []
            finally:
                temp.cleanup()

        for initial in (
            '{"gateway":[]}\n',
            '{"gateway":{"auth":[]}}\n',
            '{"plugins":[]}\n',
            '{"tools":[]}\n',
        ):
            temp, config_dir, config_path, result = self._valid_config(initial_config=initial)
            try:
                assert result.returncode != 0, initial
                assert "must be a JSON object" in result.stderr
                assert config_path.read_text() == initial
                assert list(config_dir.glob(".openclaw.json.*.tmp")) == []
            finally:
                temp.cleanup()

        result = subprocess.run(
            ["node", str(self.configure_script)],
            capture_output=True,
            text=True,
            env={
                "PATH": os.environ["PATH"],
                "OPENCLAW_GATEWAY_TOKEN": "fresh-token",
            },
            timeout=10,
            check=False,
        )
        assert result.returncode != 0
        assert "OPENCLAW_STATE_DIR" in result.stderr

    def assert_valid_inputs_produce_protected_config(self):
        providers = {
            "openai": {
                "api": "openai-responses",
                "baseUrl": "https://api.openai.com/v1",
                "apiKey": "${OPENAI_API_KEY}",
                "models": [{"id": "gpt-5"}],
            }
        }
        initial = '{"gateway":{"auth":{"token":"stale-token"}}}\n'
        env_text = (
            "OPENCLAW_GATEWAY_TOKEN=legacy-token\n"
            "OPENAI_API_KEY=preserve-me\n"
            "NODE_ENV=production\n"
        )
        temp, config_dir, config_path, result = self._valid_config(
            {
                "OPENCLAW_PUBLIC_URL": "https://openclaw.example",
                "OPENCLAW_PROVIDERS": json.dumps(providers),
            },
            initial_config=initial,
            env_text=env_text,
        )
        try:
            assert result.returncode == 0, result.stderr
            prior_path = config_dir / "prior-openclaw.json"
            assert prior_path.read_text() == initial
            assert config_path.stat().st_ino != prior_path.stat().st_ino
            config = json.loads(config_path.read_text())
            assert config["gateway"]["auth"]["token"] == "fresh-token"
            assert config["gateway"]["auth"]["rateLimit"] == {
                "maxAttempts": 10,
                "windowMs": 60000,
                "lockoutMs": 300000,
            }
            assert config["gateway"]["bind"] == "lan"
            assert config["gateway"]["controlUi"]["allowedOrigins"] == [
                "http://localhost:18789",
                "http://127.0.0.1:18789",
                "https://openclaw.example",
            ]
            assert config["models"]["providers"]["openai"] == {
                "api": "openai-responses",
                "baseUrl": "https://api.openai.com/v1",
                "apiKey": "${OPENAI_API_KEY}",
                "models": [{"id": "gpt-5"}],
            }
            assert config["tools"]["exec"]["mode"] == "ask"
            assert config["agents"]["defaults"]["skills"] == ["team-prs"]
            assert stat.S_IMODE(config_path.stat().st_mode) == 0o600
            assert list(config_dir.glob(".openclaw.json.*.tmp")) == []
            sanitized_env = (config_dir / ".env").read_text()
            assert "OPENCLAW_GATEWAY_TOKEN=" not in sanitized_env
            assert "OPENAI_API_KEY=preserve-me" in sanitized_env
            assert "NODE_ENV=production" in sanitized_env
        finally:
            temp.cleanup()

    def assert_managed_config_path_is_supported(self):
        assert 'export OPENCLAW_STATE_DIR="${CONFIG_DIR}"' in self.entrypoint
        assert 'export OPENCLAW_CONFIG_PATH="${CONFIG_DIR}/openclaw.json"' in self.entrypoint
        assert "ENV OPENCLAW_STATE_DIR=" not in self.containerfile
        assert "OPENCLAW_CONFIG_PATH=/sandbox/.openclaw/openclaw.json" not in self.containerfile
        assert "OPENCLAW_STATE_DIR=/sandbox/persist/.openclaw" in self.readme
        assert "OPENCLAW_CONFIG_DIR=/sandbox/persist/.openclaw" not in self.readme
        assert 'chmod 700 "${CONFIG_DIR}" "${WORKSPACE_DIR}"' in self.entrypoint

    def assert_runtime_install_denial_is_immediate(self):
        process = subprocess.Popen(
            [str(self.root / "csb/openclaw-install-policy")],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        selector = selectors.DefaultSelector()
        try:
            selector.register(process.stdout, selectors.EVENT_READ)
            process.stdin.write('{"target":"plugin"}\n')
            process.stdin.flush()
            assert selector.select(timeout=1), "install-policy waited for stdin EOF"
            response = json.loads(process.stdout.readline())
            assert response["decision"] == "block"
        finally:
            selector.close()
            process.kill()
            process.wait(timeout=2)

    def assert_build_inputs_are_immutable(self):
        assert "ARG CSB_BASE_IMAGE=quay.io/redhat-et/openshell:base-2026.07.16@sha256:15146a75be5d581d9809282c3368829e6c6ff93ea492fd9df5fe2718c478de6c" in self.containerfile
        assert "FROM registry.access.redhat.com/ubi10/nodejs-22@sha256:2c1743a8715377414ecb9af86076d6fb4fb566418ddde09ffd96a23d7a8d938f AS builder" in self.containerfile
        assert "ARG OPENCLAW_COMMIT=2d2ddc43d0dcf71f31283d780f9fe9ff4cc04fe4" in self.containerfile
        assert 'test "$(git rev-parse HEAD)" = "${OPENCLAW_COMMIT}"' in self.containerfile
        assert "pnpm install --frozen-lockfile" in self.containerfile
        assert "--no-frozen-lockfile" not in self.containerfile
        assert "find node_modules -type l" in self.containerfile
        assert "find node_modules -maxdepth 3 -type l" not in self.containerfile
        assert "COPY --from=builder --chown=0:0 /build /app" in self.containerfile
        assert "node /app/dist/index.js --version" in self.containerfile

    def assert_production_dependency_selection_fails_closed(self):
        selection_command = "RUN pnpm install --prod --offline --frozen-lockfile"
        selection_position = self.containerfile.index(selection_command)
        source_removal_position = self.containerfile.index(
            "RUN rm -rf extensions/ packages/ patches/"
        )
        link_resolution_position = self.containerfile.index(
            "RUN find node_modules -type l"
        )
        assert selection_position < link_resolution_position < source_removal_position
        selection_block = self.containerfile[
            selection_position:source_removal_position
        ]
        assert "|| true" not in selection_block.split("\n", 1)[0]

    def assert_openshell_policy_is_canonical(self):
        expected = """version: 1
filesystem_policy:
  include_workdir: true
  read_only:
    - /usr
    - /lib
    - /proc
    - /dev/urandom
    - /app
    - /etc
    - /var/log
  read_write:
    - /sandbox
    - /tmp
    - /dev/null
landlock:
  compatibility: best_effort
process:
  run_as_user: sandbox
  run_as_group: sandbox
network_policies:
  openai_api:
    name: openai-api
    endpoints:
      - host: api.openai.com
        port: 443
        protocol: rest
        enforcement: enforce
        rules:
          - allow:
              method: GET
              path: /v1/models
          - allow:
              method: POST
              path: /v1/responses
          - allow:
              method: POST
              path: /v1/chat/completions
    binaries:
      - path: /usr/bin/node
  github_api:
    name: github-api-readonly
    endpoints:
      - host: api.github.com
        port: 443
        access: read-only
        protocol: rest
        enforcement: enforce
    binaries:
      - path: /usr/bin/curl
"""
        assert self.policy == expected

    def assert_readme_is_reproducible(self):
        required = [
            "podman volume create openclaw-csb-data",
            '"podman":{"mounts"',
            '"source":"openclaw-csb-data"',
            '"target":"/sandbox/persist"',
            "chmod 0777 /data",
            "--policy csb/policy.yaml",
            "--cpu 2",
            "--memory 4Gi",
            "openshell forward start --background 127.0.0.1:18789 openclaw-csb",
            "OPENCLAW_ALLOWED_SKILLS",
            "OPENCLAW_STATE_DIR=/sandbox/persist/.openclaw",
            "OPENCLAW_WORKSPACE_DIR=/sandbox/persist/workspace",
            "openshell sandbox get openclaw-csb --policy-only",
            "config get agents.defaults.skills",
            "config get tools.exec.mode",
            "must be supplied on every OpenClaw start",
            "atomically replacing `openclaw.json`",
            "CSB_BASE_IMAGE` value containing an `@sha256:`",
        ]
        for text in required:
            assert text in self.readme, f"README is missing: {text}"
        assert "OPENCLAW_AI_ENV_VAR" not in self.readme
        assert "providers_v2_enabled" not in self.readme

    def assert_readme_waits_for_gateway_readiness(self):
        required = [
            "nohup /app/entrypoint.sh >/tmp/openclaw-gateway.log 2>&1 </dev/null &",
            "gateway_pid=$!",
            "for i in $(seq 1 30); do",
            "curl -fsS http://127.0.0.1:18789/healthz >/dev/null",
            'kill -0 "$gateway_pid" 2>/dev/null',
            "cat /tmp/openclaw-gateway.log >&2",
            "exit 1",
            "' &&\n  openshell forward start --background",
        ]
        for text in required:
            assert text in self.readme, f"README readiness command is missing: {text}"

        startup = self.readme.index("nohup /app/entrypoint.sh")
        readiness = self.readme.index(
            "curl -fsS http://127.0.0.1:18789/healthz", startup
        )
        failure = self.readme.index("cat /tmp/openclaw-gateway.log >&2", readiness)
        forward = self.readme.index(
            "openshell forward start --background 127.0.0.1:18789 openclaw-csb",
            failure,
        )
        assert startup < readiness < failure < forward
