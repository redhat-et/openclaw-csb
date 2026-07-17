from pathlib import Path

from behave import given

from features.support.repository_policy import RepositoryPolicy


@given("the OpenClaw CSB repository")
def step_impl(context):
    repository_root = Path(__file__).resolve().parents[3]
    context.policy = RepositoryPolicy(repository_root)
