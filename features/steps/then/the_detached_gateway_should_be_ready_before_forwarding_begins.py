from behave import then


@then("the detached gateway should be ready before forwarding begins")
def step_impl(context):
    context.policy.assert_readme_waits_for_gateway_readiness()
