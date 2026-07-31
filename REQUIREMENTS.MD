For this challenge you will implement a simple service with a REST API that simulates parts of a
radio group call management system. We will focus on floor control. The service will allow users
to obtain the floor for a specified radio group. While a user has the floor, no other user can take
the floor for that group. Users can also release the floor, after which the floor can be taken again
by another user. In this challenge we are only concerned with managing the floor, not with any
audio broadcasting.
The exact API you will implement can be found in the accompanying OpenAPI spec.
You can use any language you want for your implementation (we use Elixir). Please
containerize your application with Docker, and explain how to run your code.

Bonus Challenges (Optional)
●
Floor timeout: Implement a mechanism to automatically release the floor after a certain
period if the holder does not release it manually.
●
List floor holder: Add an endpoint to retrieve the current floor holder for a specific group.
Remember to extend the OpenAPI spec.
●
Prioritized request: Make it possible to add a priority to the request for obtaining the floor,
and allow obtaining the floor even though another user has it if your request has a higher
priority. Remember to extend the OpenAPI spec.
●
Audit endpoint: Make an endpoint to get historical data of who had the floor when on
what group. Remember to extend the OpenAPI spec.
●
CI: Setup CI pipeline running automated tests for your GitHub repo
●
Kubernetes deployment: Deploy your code on a local kubernetes cluster, for example
with kind


What is floor control:

For computer networking, floor control allows users of networked multimedia applications to utilize and share resources such as remote devices, distributed data sets, telepointers, or continuous media such as video and audio without access conflicts. Floors are temporary permissions granted dynamically to collaborating users in order to mitigate race conditions and guarantee mutually exclusive resource usage.

In floor control, a user who wishes to speak makes a request (through their user equipment unit (UE)) for the right to speak, and then waits for a response that either grants or denies the user's request. In accordance with early PoC proposals, the floor is granted only for talk burst on a first received basis, and no queuing of floor control messages is performed.