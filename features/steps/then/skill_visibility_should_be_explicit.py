from behave import then


@then("skill visibility should be explicit")
def step_impl(context):
    context.policy.assert_skill_visibility_is_explicit()
