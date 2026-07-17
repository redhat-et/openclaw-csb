from behave import then


@then("production dependency selection should fail closed")
def step_impl(context):
    context.policy.assert_production_dependency_selection_fails_closed()
