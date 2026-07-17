from behave import then


@then("invalid runtime inputs should preserve the existing configuration")
def step_impl(context):
    context.policy.assert_invalid_inputs_preserve_config()
