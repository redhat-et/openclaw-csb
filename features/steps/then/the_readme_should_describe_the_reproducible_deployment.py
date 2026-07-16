from behave import then


@then("the README should describe the reproducible deployment")
def step_impl(context):
    context.policy.assert_readme_is_reproducible()
