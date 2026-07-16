from behave import when


@when("the CSB security artifacts are inspected")
def step_impl(context):
    context.policy.load()
