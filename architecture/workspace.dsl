workspace "Codecrafters Redis (Haskell)" "C4 model for a from-scratch Redis server implementation in Haskell" {

    model {
        client = softwareSystem "Redis Client" "A client application (e.g. redis-cli or the CodeCrafters test harness) that speaks the RESP protocol." "External"

        redisServer = softwareSystem "Redis Server" "A from-scratch Haskell implementation of a Redis server supporting PING, ECHO, SET and GET over the RESP protocol." {
            // The ADRs in ../decisions are not imported: the structurizr/mcp
            // container runs with structurizr.feature.dsl.decisions disabled,
            // so `!adrs ../decisions` cannot be parsed or validated here.

            serverProcess = container "Redis Server" "Serves RESP commands from many concurrent client connections against an in-memory key-value store, using one lightweight thread per connection." "Haskell, network-simple, STM" {

                // Components follow the codebase's own structural unit, which is
                // now the *workflow*: one module group per command, each
                // declaring the effects it needs as mtl constraints and naming
                // no monad stack. The `modules` property records the
                // component-to-module mapping for architecture/check_drift.py.

                tcpListener = component "TCP Listener" "Accepts TCP connections on port 6379 and owns the per-connection read/write loop. Holds the read buffer, turns buffered bytes into RESP frames and serializes replies back out (ADR 0003)." "Haskell, network-simple" {
                    properties {
                        "modules" "Main"
                    }
                }

                dispatcher = component "Command Dispatcher" "The composition root. Routes a decoded Command to the matching workflow and interprets its declared effects. SET and GET now have the same effect shape, so they share one runner; PING and ECHO need none. The only place in the codebase that names a concrete monad stack." "Haskell, mtl" {
                    properties {
                        "modules" "Redis"
                    }
                }

                commandDto = component "Command DTO & Errors" "The shared inbound vocabulary: the Command type and its per-command payloads, fromResp to decode a Resp frame into one, and RedisError - every way a command can fail, as a domain value, including a wrong-data-type reply. Depended on by the Dispatcher and by the workflows alike, which is why it is its own component rather than part of either." "Haskell" {
                    properties {
                        "modules" "Redis.Data.Command,Redis.Data.Error"
                    }
                }

                pingWorkflow = component "PING Workflow" "Answers PING with PONG. Entirely pure - its type mentions no monad at all." "Haskell" {
                    properties {
                        "modules" "Redis.Workflows.Ping,Redis.Workflows.Ping.Data"
                    }
                }

                echoWorkflow = component "ECHO Workflow" "Echoes the argument back as a bulk string. Entirely pure - its type mentions no monad at all." "Haskell" {
                    properties {
                        "modules" "Redis.Workflows.Echo,Redis.Workflows.Echo.Data"
                    }
                }

                setWorkflow = component "SET Workflow" "Validates the EX/PX options into a single expiry, stamps the insertion time, and writes a whole record. Declares MonadReader, MonadError and MonadIO." "Haskell, mtl" {
                    properties {
                        "modules" "Redis.Workflows.Set,Redis.Workflows.Set.Data"
                    }
                }

                getWorkflow = component "GET Workflow" "Reads a key, applies the expiry rule to the record it gets back, and replies with the string, a null bulk string, or an error. Declares MonadReader, MonadError and MonadIO: now that a value can be a list, GET can be asked for something no bulk string can answer." "Haskell, mtl" {
                    properties {
                        "modules" "Redis.Workflows.Get,Redis.Workflows.Get.Data"
                    }
                }

                storePort = component "Store Port" "Declares the store as data - a record of two IO actions - without performing any of it. Traffics in whole records rather than bare values, so nothing below the port has to interpret what it is storing." "Haskell" {
                    properties {
                        "modules" "Redis.Data.Store"
                    }
                }

                recordModel = component "Stored Value & Expiry Rule" "What a stored value is - RedisString or RedisList, with more to come - and when it is still live: expiresAt / isLive / liveValue. The one real business rule in the program. It sits above the port, so the workflows apply it and the adapter cannot." "Haskell" {
                    properties {
                        "modules" "Redis.Data.Record,Redis.Data.DataType"
                    }
                }

                keyValueStore = component "In-Memory Key-Value Store" "Implements the store port over an STM-backed map (ADR 0004). A map and nothing else: it does not read the clock, and it does not decide what has expired. Its only import is the port it implements." "Haskell, STM + stm-containers" {
                    properties {
                        "modules" "Redis.Store"
                    }
                }

                respProtocol = component "RESP Protocol" "A standalone, dependency-free library for the RESP wire format: the Resp AST, a ToResp class, and the parser and serializer that move between the AST and bytes." "Haskell, Megaparsec" {
                    properties {
                        "modules" "Resp,Resp.Data,Resp.Serialization"
                    }
                }

                expiryReaper = component "Expiry Reaper" "Background sweeper that actively evicts expired keys from the store, instead of relying only on the lazy expiry check done at GET time." "Haskell" "Proposed"

                client -> tcpListener "Sends RESP-encoded commands" "RESP over TCP/6379"
                tcpListener -> client "Sends RESP-encoded replies" "RESP over TCP/6379"

                tcpListener -> respProtocol "Parses buffered bytes into a Resp frame and serializes the reply back into bytes" "Haskell function call"
                tcpListener -> dispatcher "Hands each complete frame over" "Haskell function call"
                tcpListener -> storePort "Holds the RedisStore for the lifetime of the process" "Haskell value"
                tcpListener -> keyValueStore "Creates the STM-backed store at startup, via the constructor the Dispatcher re-exports" "Haskell function call"

                dispatcher -> commandDto "Decodes the frame into a typed Command with fromResp" "Haskell function call"
                dispatcher -> respProtocol "Renders every reply and error through ToResp" "Haskell function call"
                dispatcher -> pingWorkflow "Routes PING; runs it with no monad at all" "Haskell function call"
                dispatcher -> echoWorkflow "Routes ECHO; runs it with no monad at all" "Haskell function call"
                dispatcher -> setWorkflow "Routes SET; runs it through runExceptT . runReaderT" "runEffectful (ReaderT + ExceptT)"
                dispatcher -> getWorkflow "Routes GET; runs it through the same runner as SET" "runEffectful (ReaderT + ExceptT)"
                dispatcher -> storePort "Reads the port's fields to build each workflow's Env" "Record field access"

                echoWorkflow -> commandDto "Takes its payload type" "Haskell type"
                setWorkflow -> commandDto "Takes its payload type, and the errors it can throw" "Haskell type"
                getWorkflow -> commandDto "Takes its payload type, and the WrongDataType error it can now throw" "Haskell type"
                commandDto -> respProtocol "fromResp reads the Resp AST; RedisError renders through ToResp" "Haskell function call"

                setWorkflow -> storePort "Asks for the one function it needs: setKey" "MonadReader Env"
                getWorkflow -> storePort "Asks for the one function it needs: getKey" "MonadReader Env"

                storePort -> recordModel "The port's two signatures are written in terms of a record" "Haskell type"
                setWorkflow -> recordModel "Reads the clock and builds the record it is about to store" "Haskell function call"
                getWorkflow -> recordModel "Applies isLive to the record, and unwraps a RedisString" "Haskell function call"

                // Runtime-only: the workflow calls a function value handed to it in
                // its Env. There is no compile-time dependency in this direction -
                // that is the dependency inversion - so these are excluded from the
                // static component views and appear only in the dynamic ones.
                setWorkflow -> keyValueStore "Calls the setKey closure it was handed" "Haskell closure, via the Env" "Runtime"
                getWorkflow -> keyValueStore "Calls the getKey closure it was handed" "Haskell closure, via the Env" "Runtime"

                pingWorkflow -> respProtocol "Renders its Reply through ToResp" "ToResp instance"
                echoWorkflow -> respProtocol "Renders its Reply through ToResp" "ToResp instance"
                setWorkflow -> respProtocol "Renders its Reply through ToResp" "ToResp instance"
                getWorkflow -> respProtocol "Renders its Reply through ToResp" "ToResp instance"

                keyValueStore -> storePort "Implements the port. Stores and returns records without inspecting them" "Implements the record of IO actions"
                keyValueStore -> recordModel "Names the record type it stores, and nothing more - it never calls isLive" "Haskell type"

                expiryReaper -> recordModel "Reuses isLive, so eviction and expiry-on-read cannot disagree" "Haskell function call" "Proposed"
                expiryReaper -> keyValueStore "Periodically scans for and evicts expired keys" "STM transaction" "Proposed"
            }
        }
    }

    views {
        systemContext redisServer "SystemContext" {
            include *
            autoLayout
        }

        container redisServer "Containers" {
            include *
            autoLayout
        }

        component serverProcess "ComponentsCurrent" "Current architecture. The old monolithic Command Handler is gone: there is one component per command, each declaring the effects it uses, and a Dispatcher that interprets them. PING and ECHO reach only the RESP Protocol - they perform no I/O at all. Note this diagram grows by one component per command; if that becomes the dominant cost, collapse the four workflows into one component and keep the Dispatcher split." {
            include *
            exclude "element.tag==Proposed"
            exclude "relationship.tag==Runtime"
            autoLayout
        }

        component serverProcess "ComponentsTarget" "Target architecture: the Expiry Reaper is added (ADR 0002). It depends on the Store Port rather than on the store adapter's own copy of the rule, so lazy expiry-on-read and active eviction share one definition of 'live'." {
            include *
            exclude "relationship.tag==Runtime"
            autoLayout
        }

        dynamic serverProcess "SetCommandFlowCurrent" "Current architecture: how the server handles a client SET command end-to-end. The TCP Listener owns the wire format at both ends (ADR 0003), and the workflow - not the store - reads the clock and assembles the record that gets written." {
            client -> tcpListener "Sends SET command as RESP-encoded bytes over TCP"
            tcpListener -> respProtocol "Parses the buffered bytes into a Resp frame" "Haskell function call"
            tcpListener -> dispatcher "Hands the frame over" "Haskell function call"
            dispatcher -> commandDto "fromResp decodes the frame into a Set command" "Haskell function call"
            dispatcher -> setWorkflow "Runs the workflow with an Env holding just setKey" "runEffectful (ReaderT + ExceptT)"
            setWorkflow -> recordModel "Validates EX/PX into one expiry, stamps insertedAt, wraps the value as a RedisString" "Haskell function call"
            setWorkflow -> storePort "Reads setKey out of the Env" "MonadReader Env"
            setWorkflow -> keyValueStore "Calling that closure writes the whole record into the STM map"
            dispatcher -> respProtocol "Renders the Reply - or the RedisError - through ToResp" "Haskell function call"
            tcpListener -> client "Serializes the reply and writes it back over TCP"
            autoLayout
        }

        dynamic serverProcess "GetCommandFlowCurrent" "Current architecture: how the server handles a client GET command end-to-end. The store hands back whatever record it holds; every decision after that - expired, wrong type, missing - is the workflow's, and only one of the three is a nil reply." {
            client -> tcpListener "Sends GET command as RESP-encoded bytes over TCP"
            tcpListener -> respProtocol "Parses the buffered bytes into a Resp frame" "Haskell function call"
            tcpListener -> dispatcher "Hands the frame over" "Haskell function call"
            dispatcher -> commandDto "fromResp decodes the frame into a Get command" "Haskell function call"
            dispatcher -> getWorkflow "Runs the workflow with an Env holding just getKey" "runEffectful (ReaderT + ExceptT)"
            getWorkflow -> storePort "Reads getKey out of the Env" "MonadReader Env"
            getWorkflow -> keyValueStore "Calling that closure reads the record straight out of the STM map"
            getWorkflow -> recordModel "Applies isLive, then checks the value really is a RedisString" "Haskell function call"
            dispatcher -> respProtocol "Renders the value, a nil reply for missing-or-expired, or -ERR wrong data type" "Haskell function call"
            tcpListener -> client "Serializes the reply and writes it back over TCP"
            autoLayout
        }

        dynamic serverProcess "PingCommandFlowCurrent" "Current architecture: the contrast case. PING touches no store, no Env and no monad - the Dispatcher's runner for it is `pure . toResp`. Worth keeping next to the SET and GET flows, because it is what a workflow looks like when it declares no effects." {
            client -> tcpListener "Sends PING as RESP-encoded bytes over TCP"
            tcpListener -> respProtocol "Parses the buffered bytes into a Resp frame" "Haskell function call"
            tcpListener -> dispatcher "Hands the frame over" "Haskell function call"
            dispatcher -> commandDto "fromResp decodes the frame into a Ping command" "Haskell function call"
            dispatcher -> pingWorkflow "Evaluates the workflow - a pure value, no runner needed" "Haskell function call"
            dispatcher -> respProtocol "Renders the Reply through ToResp" "Haskell function call"
            tcpListener -> client "Serializes the reply and writes it back over TCP"
            autoLayout
        }

        styles {
            element "Software System" {
                background #1168bd
                color #ffffff
            }
            element "External" {
                background #999999
                color #ffffff
            }
            element "Container" {
                background #438dd5
                color #ffffff
            }
            element "Component" {
                background #85bbf0
                color #000000
            }
            element "Proposed" {
                background #ffffff
                color #d35400
                stroke #d35400
                strokeWidth 3
                border dashed
            }
            relationship "Proposed" {
                style dashed
                color #d35400
            }
            relationship "Runtime" {
                style dotted
                color #6d28d9
            }
        }
    }

    configuration {
        scope softwaresystem
    }
}
