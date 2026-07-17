from behave import then


@then("build inputs should be immutable")
def step_impl(context):
    context.policy.assert_build_inputs_are_immutable()
