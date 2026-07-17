from behave import then


@then("valid runtime inputs should produce protected configuration")
def step_impl(context):
    context.policy.assert_valid_inputs_produce_protected_config()
