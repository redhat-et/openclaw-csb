from behave import then


@then("runtime installs should fail closed")
def step_impl(context):
    context.policy.assert_runtime_installs_fail_closed()
