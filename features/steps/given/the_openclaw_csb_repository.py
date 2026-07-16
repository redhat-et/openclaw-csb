from pathlib import Path

from behave import given

from features.support.repository_policy import RepositoryPolicy


@given("the OpenClaw CSB repository")
def step_impl(context):
    context.policy = RepositoryPolicy(Path.cwd())
