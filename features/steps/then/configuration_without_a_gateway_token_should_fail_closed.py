from behave import then


@then("configuration without a gateway token should fail closed")
def step_impl(context):
    context.policy.assert_missing_token_fails_closed()
