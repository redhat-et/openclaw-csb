from behave import then


@then("the OpenShell policy should be canonical and least privilege")
def step_impl(context):
    context.policy.assert_openshell_policy_is_canonical()
