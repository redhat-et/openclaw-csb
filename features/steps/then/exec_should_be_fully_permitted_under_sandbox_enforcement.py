from behave import then


@then("exec should be fully permitted under sandbox enforcement")
def step_impl(context):
    context.policy.assert_exec_is_fully_permitted()
