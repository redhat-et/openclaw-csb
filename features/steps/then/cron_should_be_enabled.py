from behave import then


@then("cron should be enabled")
def step_impl(context):
    context.policy.assert_cron_is_enabled()
