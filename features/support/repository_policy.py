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

    def assert_exec_requires_approval(self):
        assert 'cfg.tools.exec.mode             = "ask";' in self.entrypoint
        assert 'cfg.tools.exec.mode             = "deny";' not in self.entrypoint
        assert 'cfg.tools.exec.mode             = "full";' not in self.entrypoint
        assert "dist/index.js onboard" not in self.entrypoint

    def assert_skill_visibility_is_explicit(self):
        assert "OPENCLAW_ALLOWED_SKILLS" in self.entrypoint
        assert 'process.env.OPENCLAW_ALLOWED_SKILLS || "[]"' in self.entrypoint
        assert "cfg.agents.defaults.skills" in self.entrypoint
        assert "Array.isArray" in self.entrypoint

    def assert_runtime_installs_fail_closed(self):
        assert "CSB policy prohibits runtime skill and plugin installation" in self.install_policy
        assert 'targets: ["skill", "plugin"]' in self.entrypoint
        assert 'command: "/usr/local/bin/openclaw-install-policy"' in self.entrypoint
        assert "COPY csb/openclaw-install-policy /usr/local/bin/openclaw-install-policy" in self.containerfile

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
            "OPENCLAW_CONFIG_DIR=/sandbox/persist/.openclaw",
            "OPENCLAW_WORKSPACE_DIR=/sandbox/persist/workspace",
            "openshell sandbox get openclaw-csb --policy-only",
        ]
        for text in required:
            assert text in self.readme, f"README is missing: {text}"
        assert "OPENCLAW_AI_ENV_VAR" not in self.readme
        assert "providers_v2_enabled" not in self.readme
