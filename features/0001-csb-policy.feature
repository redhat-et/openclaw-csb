@security @csb
Feature: OpenClaw CSB policy
  The repository defines the application and sandbox boundaries used by the
  documented OpenShell deployment.

  Rule: The OpenClaw CSB policy shall retain exec behind human approval.
    Scenario: Exec remains available with an approval boundary
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then exec should require human approval

  Rule: The OpenClaw CSB policy shall expose only explicitly configured skills.
    Scenario: Skill visibility defaults to no skills
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then skill visibility should be explicit

  Rule: If a runtime skill or plugin installation is requested, then the OpenClaw CSB policy shall reject the installation.
    Scenario: Runtime customization fails closed
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then runtime installs should fail closed

  Rule: The OpenShell CSB policy shall authorize only declared filesystem, identity, and network access.
    Scenario: Canonical policy declares exact boundaries
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then the OpenShell policy should be canonical and least privilege

  Rule: The OpenShell README deployment shall apply version-controlled policy and persistent Podman storage.
    Scenario: Deployment instructions reproduce the security posture
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then the README should describe the reproducible deployment
