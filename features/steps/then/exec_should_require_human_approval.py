from behave import then


@then("exec should require human approval")
def step_impl(context):
    context.policy.assert_exec_requires_approval()
