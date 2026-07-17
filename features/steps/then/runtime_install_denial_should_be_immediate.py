from behave import then


@then("runtime install denial should be immediate")
def step_impl(context):
    context.policy.assert_runtime_install_denial_is_immediate()
