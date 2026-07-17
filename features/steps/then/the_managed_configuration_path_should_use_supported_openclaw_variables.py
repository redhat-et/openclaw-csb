from behave import then


@then("the managed configuration path should use supported OpenClaw variables")
def step_impl(context):
    context.policy.assert_managed_config_path_is_supported()
