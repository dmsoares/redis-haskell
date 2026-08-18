[![progress-banner](https://backend.codecrafters.io/progress/redis/69017067-094c-4461-b706-749bb57b334f)](https://app.codecrafters.io/users/dmsoares?r=2qF)

This is a starting point for Haskell solutions to the
["Build Your Own Redis" Challenge](https://codecrafters.io/challenges/redis).

In this challenge, you'll build a toy Redis clone that's capable of handling
basic commands like `PING`, `SET` and `GET`. Along the way we'll learn about
event loops, the Redis protocol and more.

**Note**: If you're viewing this repo on GitHub, head over to
[codecrafters.io](https://codecrafters.io) to try the challenge.

# Passing the first stage

The entry point for your Redis implementation is in `app/Main.hs`. Study and
uncomment the relevant code, then run the command below to execute the tests on
our servers:

```sh
codecrafters submit
```

That's all!

# Stage 2 & beyond

Note: This section is for stages 2 and beyond.

1. Ensure you have `stack (23.18)` installed locally
1. Run `./your_program.sh` to run your Redis server, which is implemented in
   `app/Main.hs`.
1. Run `codecrafters submit` to submit your solution to CodeCrafters. Test
   output will be streamed to your terminal.
