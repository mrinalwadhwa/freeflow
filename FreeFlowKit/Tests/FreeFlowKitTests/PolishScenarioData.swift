import Foundation

@testable import FreeFlowKit

// ---------------------------------------------------------------------------
// Shared test data for all polish scenario tests. Each scenario captures a
// realistic dictation input, one or more acceptable polished outputs, and
// an optional app context for context-aware formatting.
//
// Covers fillers, corrections, punctuation, numbers, lists, homophones,
// capitalization, wording preservation, and more.
// ---------------------------------------------------------------------------

// swiftlint:disable line_length

/// A single polish scenario with category, raw input, acceptable outputs, and context.
struct PolishScenario {
    let category: String
    let input: String
    let accepted: [String]
    let context: AppContext

    init(_ category: String, _ input: String, _ accepted: String..., context: AppContext = .empty) {
        self.category = category
        self.input = input
        self.accepted = accepted
        self.context = context
    }

    func matches(_ output: String) -> Bool {
        let normalize = { (s: String) in
            s.replacingOccurrences(of: "\u{2019}", with: "'")
             .replacingOccurrences(of: "\u{2018}", with: "'")
             .replacingOccurrences(of: "\u{201C}", with: "\"")
             .replacingOccurrences(of: "\u{201D}", with: "\"")
        }
        let normalizedOutput = normalize(output)
        return accepted.contains { normalize($0) == normalizedOutput }
    }
}

/// All unique polish scenarios across all test suites (~113 cases).
let allScenarios: [PolishScenario] = [

    // ── Filler ──

    PolishScenario("filler",
        "um so I was thinking we should um probably update the documentation",
        "I was thinking we should probably update the documentation."),
    PolishScenario("filler",
        "like I basically just need to uh figure out the API rate limits you know",
        "I just need to figure out the API rate limits.",
        "I need to figure out the API rate limits."),
    PolishScenario("filler",
        "so yeah I mean the deployment went fine right but we should still monitor it",
        "The deployment went fine, but we should still monitor it."),
    PolishScenario("filler",
        "it's like literally the most important thing we need to do",
        "It's the most important thing we need to do."),
    PolishScenario("filler",
        "well actually I think we should wait until Monday",
        "I think we should wait until Monday."),
    PolishScenario("filler",
        "okay so basically what happened was the server crashed at 3 AM",
        "The server crashed at 3 AM.",
        "The server crashed at 3 a.m."),
    PolishScenario("filler",
        "I just wanted to say that um we really need to uh prioritize this",
        "We really need to prioritize this."),
    PolishScenario("filler",
        "yeah no totally I agree with that approach",
        "I agree with that approach."),

    // ── Discourse ──

    PolishScenario("discourse",
        "so the thing is we need more budget for Q3",
        "We need more budget for Q3."),
    PolishScenario("discourse",
        "I mean at the end of the day it's about user experience",
        "At the end of the day, it's about user experience."),
    PolishScenario("discourse",
        "right so basically we should just ship it",
        "We should just ship it."),
    PolishScenario("discourse",
        "you see the problem is that we don't have enough test coverage",
        "The problem is that we don't have enough test coverage."),
    PolishScenario("discourse",
        "honestly I think the current design is fine",
        "Honestly, I think the current design is fine.",
        "I think the current design is fine."),

    // ── Thinking ──

    PolishScenario("thinking",
        "hmm I think the best approach would be to refactor first",
        "I think the best approach would be to refactor first."),
    PolishScenario("thinking",
        "mm let me think ah yes we should use the new API",
        "We should use the new API."),
    PolishScenario("thinking",
        "uh huh so the meeting is at 3",
        "The meeting is at 3."),
    PolishScenario("thinking",
        "mm hmm that makes sense let's go with plan B",
        "That makes sense. Let's go with plan B.",
        "That makes sense. Let's go with Plan B."),
    PolishScenario("thinking",
        "ah right I forgot about that constraint",
        "I forgot about that constraint."),

    // ── Repetition ──

    PolishScenario("repetition",
        "I think I think we should fix the the login bug",
        "I think we should fix the login bug."),
    PolishScenario("repetition",
        "the problem is the problem is that we don't have enough test coverage",
        "The problem is that we don't have enough test coverage."),
    PolishScenario("repetition",
        "we need to we need to make sure that everything is backed up",
        "We need to make sure that everything is backed up."),
    PolishScenario("repetition",
        "can you can you send me the report by Friday",
        "Can you send me the report by Friday?"),
    PolishScenario("repetition",
        "it's it's really important that we that we get this right",
        "It's really important that we get this right."),

    // ── Correction ──

    PolishScenario("correction",
        "send the report to John no wait send it to Sarah instead",
        "Send the report to Sarah.",
        "Send the report to Sarah instead."),
    PolishScenario("correction",
        "the deadline is Friday I mean Monday the deadline is Monday",
        "The deadline is Monday."),
    PolishScenario("correction",
        "we should use Python actually let's use Rust for this",
        "Let's use Rust for this."),
    PolishScenario("correction",
        "the meeting is at 2 sorry 3 PM tomorrow",
        "The meeting is at 3 PM tomorrow.",
        "The meeting is at 3 p.m. tomorrow."),
    PolishScenario("correction",
        "let me rephrase the project will take two weeks not three",
        "The project will take two weeks, not three."),
    PolishScenario("correction",
        "we have five hundred no wait five thousand active users",
        "We have 5,000 active users.",
        "We have 5000 active users."),
    PolishScenario("correction",
        "I'll book the flight for Tuesday actually make that Wednesday",
        "I'll book the flight for Wednesday."),
    PolishScenario("correction",
        "the budget is fifty thousand or rather sixty thousand dollars",
        "The budget is $60,000."),

    // ── Backtrack ──

    PolishScenario("backtrack",
        "the cost is two actually three hundred dollars per month",
        "The cost is $300 per month."),
    PolishScenario("backtrack",
        "I'll be there in ten no twenty minutes",
        "I'll be there in 20 minutes."),
    PolishScenario("backtrack",
        "we need three no four developers on this project",
        "We need 4 developers on this project."),

    // ── Punctuation ──

    PolishScenario("punctuation",
        "dear team comma I wanted to follow up on the project period",
        "Dear team, I wanted to follow up on the project."),
    PolishScenario("punctuation",
        "is this working question mark",
        "Is this working?"),
    PolishScenario("punctuation",
        "that's great exclamation point",
        "That's great!"),
    PolishScenario("punctuation",
        "the options are colon option A semicolon option B semicolon and option C",
        "The options are: option A; option B; and option C."),
    PolishScenario("punctuation",
        "he said open quote I'll be there close quote",
        "He said \u{201c}I'll be there.\u{201d}",
        "He said, \u{201c}I'll be there.\u{201d}"),
    PolishScenario("punctuation",
        "check the function open paren user ID close paren",
        "Check the function (user ID).",
        "Check the function (userID)."),
    PolishScenario("punctuation",
        "first paragraph new paragraph second paragraph",
        "First paragraph.\n\nSecond paragraph."),
    PolishScenario("punctuation",
        "add a note new line then add the details",
        "Add a note.\nThen add the details."),
    PolishScenario("punctuation",
        "wait dot dot dot I need to think about this",
        "Wait\u{2026} I need to think about this."),

    // ── Number ──

    PolishScenario("number",
        "the conversion rate is twenty three point five percent",
        "The conversion rate is 23.5%."),
    PolishScenario("number",
        "the budget is five hundred thousand dollars",
        "The budget is $500,000."),
    PolishScenario("number",
        "we have twelve million active users",
        "We have 12 million active users."),
    PolishScenario("number",
        "the temperature is minus forty degrees Celsius",
        "The temperature is -40\u{00b0}C."),
    PolishScenario("number",
        "my phone number is five five five one two three four five six seven",
        "My phone number is 555-123-4567."),
    PolishScenario("number",
        "the meeting is at two thirty PM on March fifteenth",
        "The meeting is at 2:30 PM on March 15th.",
        "The meeting is at 2:30 p.m. on March 15th."),
    PolishScenario("number",
        "version three point fourteen point one",
        "Version 3.14.1",
        "Version 3.14.1."),
    PolishScenario("number",
        "the ratio is one to four",
        "The ratio is 1:4."),
    PolishScenario("number",
        "it costs ninety nine dollars and ninety nine cents",
        "It costs $99.99.",
        "It costs $99.99"),

    // ── List ──

    PolishScenario("list",
        "the priorities are first fix the login bug second add caching third write documentation",
        "The priorities are:\n1. Fix the login bug\n2. Add caching\n3. Write documentation"),
    PolishScenario("list",
        "I need to buy eggs milk bread butter and cheese",
        "I need to buy:\n- Eggs\n- Milk\n- Bread\n- Butter\n- Cheese"),
    PolishScenario("list",
        "step one clone the repo step two install dependencies step three run tests step four deploy",
        "1. Clone the repo\n2. Install dependencies\n3. Run tests\n4. Deploy"),
    PolishScenario("list",
        "please order five monitors three keyboards and ten mice",
        "Please order:\n- 5 monitors\n- 3 keyboards\n- 10 mice"),
    PolishScenario("list",
        "the action items from the meeting are update the roadmap schedule a design review and hire two more engineers",
        "The action items from the meeting are:\n- Update the roadmap\n- Schedule a design review\n- Hire two more engineers"),

    // ── Capitalization ──

    PolishScenario("capitalization",
        "i went to new york last week and met with john from google",
        "I went to New York last week and met with John from Google."),
    PolishScenario("capitalization",
        "we're using kubernetes on aws with a postgres database",
        "We're using Kubernetes on AWS with a Postgres database.",
        "We are using Kubernetes on AWS with a Postgres database."),
    PolishScenario("capitalization",
        "can you ask sarah from the london office about the api changes",
        "Can you ask Sarah from the London office about the API changes?"),
    PolishScenario("capitalization",
        "the iphone sixteen pro max runs ios eighteen",
        "The iPhone 16 Pro Max runs iOS 18."),
    PolishScenario("capitalization",
        "microsoft teams doesn't work well with google chrome on macos",
        "Microsoft Teams doesn't work well with Google Chrome on macOS."),

    // ── Run-on ──

    PolishScenario("run-on",
        "so the thing is we tried to deploy on Friday but the tests failed and then we had to roll back and then on Monday we fixed the issue and redeployed and it worked",
        "We tried to deploy on Friday, but the tests failed, so we had to roll back. On Monday, we fixed the issue and redeployed, and it worked.",
        "We tried to deploy on Friday, but the tests failed and we had to roll back. On Monday we fixed the issue and redeployed, and it worked.",
        "We tried to deploy on Friday but the tests failed. We had to roll back. On Monday we fixed the issue and redeployed, and it worked."),
    PolishScenario("run-on",
        "I talked to the client and they want the feature by next week and also they asked about pricing and I told them we'd send a proposal",
        "I talked to the client. They want the feature by next week. They also asked about pricing, and I told them we'd send a proposal."),
    PolishScenario("run-on",
        "we need to update the database and then run the migrations and then restart the service and then verify that everything is working and then notify the team",
        "We need to update the database, run the migrations, and restart the service. Then verify that everything is working and notify the team."),

    // ── False Start ──

    PolishScenario("false-start",
        "I was going to say but never mind the point is we need more testing",
        "The point is we need more testing."),
    PolishScenario("false-start",
        "what if we no that won't work let's just use the existing approach",
        "Let's just use the existing approach."),
    PolishScenario("false-start",
        "maybe we could or actually no let's just go with the original plan",
        "Let's just go with the original plan."),
    PolishScenario("false-start",
        "I think we should try to hmm actually you know what let me come back to this later",
        "Let me come back to this later."),

    // ── Email ──

    PolishScenario("email",
        "hey can you um send me the thing we talked about yesterday like the report or whatever",
        "Hi, could you send me the report we discussed yesterday?",
        context: AppContext(bundleID: "com.apple.mail", appName: "Mail", windowTitle: "New Message")),
    PolishScenario("email",
        "thanks for getting back to me so I wanted to follow up on the proposal we sent last week",
        "Thanks for getting back to me. I wanted to follow up on the proposal we sent last week.",
        context: AppContext(bundleID: "com.apple.mail", appName: "Mail", windowTitle: "Re: Proposal")),
    PolishScenario("email",
        "just circling back on this um are we still on track for the launch next Thursday",
        "Just circling back on this \u{2014} are we still on track for the launch next Thursday?",
        "Just circling back on this, are we still on track for the launch next Thursday?",
        context: AppContext(bundleID: "com.apple.mail", appName: "Mail", windowTitle: "Re: Launch")),

    // ── Slack ──

    PolishScenario("slack",
        "yeah looks good to me let's ship it",
        "yeah looks good to me, let's ship it",
        context: AppContext(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", windowTitle: "#engineering")),
    PolishScenario("slack",
        "haha nice one okay I'll review it after lunch",
        "haha nice one, okay I'll review it after lunch",
        context: AppContext(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", windowTitle: "#random")),
    PolishScenario("slack",
        "lgtm merge it",
        "lgtm, merge it",
        context: AppContext(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", windowTitle: "#code-review")),

    // ── Code ──

    PolishScenario("code",
        "define a function called get user by ID that takes a user ID parameter",
        "Define a function called getUserById that takes a userId parameter.",
        context: AppContext(bundleID: "com.microsoft.VSCode", appName: "VS Code", windowTitle: "app.ts")),
    PolishScenario("code",
        "the variable should be named max retry count in snake case",
        "The variable should be named max_retry_count."),
    PolishScenario("code",
        "add a comment that says TODO fix this before release",
        "// TODO: Fix this before release",
        context: AppContext(bundleID: "com.microsoft.VSCode", appName: "VS Code", windowTitle: "main.swift")),
    PolishScenario("code",
        "import react from react and import use state from react",
        "import React from 'react'; import useState from 'react';",
        context: AppContext(bundleID: "com.microsoft.VSCode", appName: "VS Code", windowTitle: "App.jsx")),
    PolishScenario("code",
        "create a constant called API base URL equals https colon forward slash forward slash api dot example dot com",
        "const API_BASE_URL = 'https://api.example.com'",
        context: AppContext(bundleID: "com.microsoft.VSCode", appName: "VS Code", windowTitle: "config.ts")),

    // ── Homophone ──

    PolishScenario("homophone",
        "I need to by some groceries",
        "I need to buy some groceries."),
    PolishScenario("homophone",
        "I'll send it to you're email",
        "I'll send it to your email."),
    PolishScenario("homophone",
        "their going to be late for the meeting",
        "They're going to be late for the meeting.",
        "They are going to be late for the meeting.",
        "They\u{2019}re going to be late for the meeting."),
    PolishScenario("homophone",
        "the affect on performance was significant",
        "The effect on performance was significant."),
    PolishScenario("homophone",
        "we need to ensure the data is compliant with there policies",
        "We need to ensure the data is compliant with their policies."),
    PolishScenario("homophone",
        "its important that it's configuration is correct",
        "It's important that its configuration is correct.",
        "It is important that its configuration is correct.",
        "It\u{2019}s important that its configuration is correct."),

    // ── Apple Bug ──

    PolishScenario("apple-bug",
        "I will be there at 3, PM,, tomorrow,",
        "I will be there at 3 PM tomorrow.",
        "I will be there at 3 p.m. tomorrow.",
        "I will be there at 3:00 PM tomorrow."),
    PolishScenario("apple-bug",
        "the report is due due on Friday",
        "The report is due on Friday."),
    PolishScenario("apple-bug",
        "Let me know if you have any, questions, about the, project.",
        "Let me know if you have any questions about the project."),

    // ── URL ──

    PolishScenario("url",
        "check out our website at www dot example dot com",
        "Check out our website at www.example.com."),
    PolishScenario("url",
        "send it to john at example dot com",
        "Send it to john@example.com.",
        "Send it to john@example.com"),
    PolishScenario("url",
        "the API endpoint is slash API slash v2 slash users",
        "The API endpoint is /api/v2/users."),

    // ── Vocab ──

    PolishScenario("vocab",
        "we're deploying the kubernetes cluster on GKE with istio service mesh",
        "We're deploying the Kubernetes cluster on GKE with Istio service mesh."),
    PolishScenario("vocab",
        "the bug was reported by priya from the bangalore team",
        "The bug was reported by Priya from the Bangalore team."),
    PolishScenario("vocab",
        "use the fetch API with the authorization header set to bearer token",
        "Use the Fetch API with the Authorization header set to Bearer token."),

    // ── Preserve ──

    PolishScenario("preserve",
        "I wanted to grab some coffee before the meeting.",
        "I wanted to grab some coffee before the meeting."),
    PolishScenario("preserve",
        "I wanted to grab some coffee before the meeting",
        "I wanted to grab some coffee before the meeting."),
    PolishScenario("preserve",
        "He mentioned that the deadline might slip.",
        "He mentioned that the deadline might slip."),
    PolishScenario("preserve",
        "he mentioned that the deadline might slip",
        "He mentioned that the deadline might slip."),
    PolishScenario("preserve",
        "The thing is kinda broken.",
        "The thing is kinda broken."),
    PolishScenario("preserve",
        "the thing is kinda broken",
        "The thing is kinda broken."),
    PolishScenario("preserve",
        "I reckon we should ship it by Friday",
        "I reckon we should ship it by Friday."),

    // ── Clean ──

    PolishScenario("clean",
        "The deployment went smoothly.",
        "The deployment went smoothly."),
    PolishScenario("clean",
        "Can you review the pull request by end of day?",
        "Can you review the pull request by end of day?"),
    PolishScenario("clean",
        "I'll be in the office from 9 AM to 5 PM.",
        "I'll be in the office from 9 AM to 5 PM."),
    PolishScenario("clean",
        "The meeting is scheduled for March 15th at 2:30 PM.",
        "The meeting is scheduled for March 15th at 2:30 PM.",
        "The meeting is scheduled for March 15th at 2:30 p.m."),

    // ── Multilingual ──

    PolishScenario("multilingual",
        "we should use the raison d'etre of the project as our north star",
        "We should use the raison d'\u{00ea}tre of the project as our north star.",
        "We should use the raison d'\u{00ea}tre of the project as our North Star."),
    PolishScenario("multilingual",
        "the restaurant is called cafe del sol on fifth avenue",
        "The restaurant is called Caf\u{00e9} del Sol on Fifth Avenue.",
        "The restaurant is called Cafe del Sol on Fifth Avenue."),
    PolishScenario("multilingual",
        "abhi meeting mein discuss karte hain then we'll send the proposal",
        "\u{0905}\u{092d}\u{0940} meeting \u{092e}\u{0947}\u{0902} discuss \u{0915}\u{0930}\u{0924}\u{0947} \u{0939}\u{0948}\u{0902}, then we'll send the proposal."),

    // ── Emphasis ──

    PolishScenario("emphasis",
        "this is really really important please don't forget",
        "This is really really important. Please don't forget.",
        "This is really important. Please don't forget.",
        "This is really important \u{2014} please don't forget."),
    PolishScenario("emphasis",
        "no no no that's completely wrong we need to start over",
        "No, no, no, that's completely wrong. We need to start over.",
        "No, no, no. That's completely wrong. We need to start over.",
        "No, that's completely wrong. We need to start over."),

    // ── Meeting ──

    PolishScenario("meeting",
        "okay so in today's standup um john said the backend API is ready sarah mentioned she's blocked on the design review and mike said he'll finish the tests by tomorrow",
        "In today's standup:\n- John said the backend API is ready.\n- Sarah mentioned she's blocked on the design review.\n- Mike said he'll finish the tests by tomorrow."),
    PolishScenario("meeting",
        "the key takeaways from the meeting are one we need to hire two more engineers two the deadline is moved to April fifteenth and three we should schedule a follow up for next week",
        "The key takeaways from the meeting are:\n1. We need to hire 2 more engineers.\n2. The deadline is moved to April 15th.\n3. We should schedule a follow-up for next week."),
    // ── Keep Tags (tests polish prompt preserving <keep>-wrapped symbols) ──

    PolishScenario("keep-tag",
        "research ampersand development is our focus",
        "Research & development is our focus."),
    PolishScenario("keep-tag",
        "I was thinking dot dot dot maybe we should wait",
        "I was thinking\u{2026} maybe we should wait.",
        "I was thinking \u{2026} maybe we should wait."),
    PolishScenario("keep-tag",
        "check the hashtag trending topic",
        "Check the #trending topic."),
    PolishScenario("keep-tag",
        "two plus sign three equals sign five",
        "2 + 3 = 5.",
        "2+3=5.",
        "2 + 3 = 5"),
    PolishScenario("keep-tag",
        "the price is dollar sign fifty with a ten percent sign discount",
        "The price is $50 with a 10% discount."),
    PolishScenario("keep-tag",
        "use asterisk bold asterisk for formatting",
        "Use *bold* for formatting."),
    PolishScenario("keep-tag",
        "first part new paragraph second part",
        "First part.\n\nSecond part."),
    PolishScenario("keep-tag",
        "see the summary new line details are below",
        "See the summary.\nDetails are below."),

    // ── Two-item Lists (should stay inline, not become vertical) ──

    PolishScenario("two-item-list",
        "I need to buy eggs and milk",
        "I need to buy eggs and milk."),
    PolishScenario("two-item-list",
        "the options are upgrade or replace",
        "The options are upgrade or replace.",
        "The options are: upgrade or replace."),
    PolishScenario("two-item-list",
        "please review the design and the implementation",
        "Please review the design and the implementation."),

    // ── No Lead-in List (should not invent introductory text) ──

    PolishScenario("no-leadin-list",
        "eggs milk bread butter and cheese",
        "Eggs, milk, bread, butter, and cheese.",
        "- Eggs\n- Milk\n- Bread\n- Butter\n- Cheese"),
    PolishScenario("no-leadin-list",
        "first update the docs second run the tests third deploy",
        "1. Update the docs\n2. Run the tests\n3. Deploy"),

    // ── Contraction Preservation ──

    PolishScenario("contraction",
        "I'll send it tomorrow and we'll review it on Monday",
        "I'll send it tomorrow and we'll review it on Monday.",
        "I'll send it tomorrow, and we'll review it on Monday."),
    PolishScenario("contraction",
        "we're planning to launch and it's going to be great",
        "We're planning to launch, and it's going to be great.",
        "We're planning to launch and it's going to be great."),
    PolishScenario("contraction",
        "they've already finished and we've just started",
        "They've already finished, and we've just started.",
        "They've already finished and we've just started."),
    PolishScenario("contraction",
        "I can't believe it doesn't work",
        "I can't believe it doesn't work."),

    // ── Small Numbers (prompt says convert ALL numbers to digits) ──

    PolishScenario("small-number",
        "we need three developers on this",
        "We need 3 developers on this."),
    PolishScenario("small-number",
        "there are two options here",
        "There are 2 options here."),
    PolishScenario("small-number",
        "I have eight files to review",
        "I have 8 files to review."),
    PolishScenario("small-number",
        "it took about thirty seconds to load",
        "It took about 30 seconds to load."),
    PolishScenario("small-number",
        "we only have one server left",
        "We only have 1 server left."),

    // ── Ordinal Numbers ──

    PolishScenario("ordinal",
        "the meeting is on the third floor",
        "The meeting is on the 3rd floor."),
    PolishScenario("ordinal",
        "she's the twenty first employee",
        "She's the 21st employee."),
    PolishScenario("ordinal",
        "this is our fifth release this year",
        "This is our 5th release this year."),

    // ── Tamil ──

    PolishScenario("fillers-ta",
        "அது வந்து நமக்கு இதை update பண்ணணும்",
        "நமக்கு இதை update பண்ணணும்."),
    PolishScenario("fillers-ta",
        "ம்ம்ம் இது ரொம்ப முக்கியம்",
        "இது ரொம்ப முக்கியம்."),
    PolishScenario("fillers-ta",
        "அப்படின்னா நாம இதை நாளைக்குள் முடிக்கணும்",
        "நாம இதை நாளைக்குள் முடிக்கணும்."),

    PolishScenario("corrections-ta",
        "report ராகுலுக்கு அனுப்பு இல்லை இல்லை அமித்துக்கு அனுப்பு",
        "report அமித்துக்கு அனுப்பு."),
    PolishScenario("corrections-ta",
        "meeting இரண்டு மணிக்கு அப்படின்னா மூன்று மணிக்கு இருக்கு",
        "meeting மூன்று மணிக்கு இருக்கு.", "meeting 3 மணிக்கு இருக்கு."),

    PolishScenario("numbers-ta",
        "budget இருபது லட்சம் ரூபாய்",
        "budget ₹20,00,000.", "budget ₹2000000.", "budget ₹2M."),
    PolishScenario("numbers-ta",
        "இதோட விலை ஐம்பத்து ஐந்து ரூபாய் ஐம்பது பைசா",
        "இதோட விலை ₹55.50.", "இதோட விலை 55.50 ரூபாய்."),
    PolishScenario("numbers-ta",
        "எனக்கு முப்பத்திரண்டு வயசு",
        "எனக்கு 32 வயசு."),

    PolishScenario("punctuation-ta",
        "வணக்கம் team comma எனக்கு update வேண்டும் full stop",
        "வணக்கம் team, எனக்கு update வேண்டும்."),
    PolishScenario("punctuation-ta",
        "இது சரியா question mark",
        "இது சரியா?"),

    PolishScenario("lists-ta",
        "நமக்கு இந்த வேலைகள் செய்யணும் முதல் login bug சரி பண்ணு இரண்டாவது புதிய feature பண்ணு மூன்றாவது test எழுது",
        "நமக்கு இந்த வேலைகள் செய்யணும்:\n1. login bug சரி பண்ணு\n2. புதிய feature பண்ணு\n3. test எழுது"),
    PolishScenario("lists-ta",
        "meetingல மூணு பேர் இருந்தாங்க ராகுல் அமித் சுமித்",
        "meetingல மூணு பேர் இருந்தாங்க:\n- ராகுல்\n- அமித்\n- சுமித்"),

    PolishScenario("code-switching-ta",
        "database update பண்ணிட்டு அப்புறம் server restart பண்ணு",
        "database update பண்ணிட்டு அப்புறம் server restart பண்ணு."),
    PolishScenario("code-switching-ta",
        "இந்த புதிய release ஓட deployment எப்போ",
        "இந்த புதிய release ஓட deployment எப்போ?", "இந்த புதிய release ஓட deployment எப்போ."),

    PolishScenario("repetitions-ta",
        "எனக்கு எனக்கு தோணுது நமக்கு நமக்கு இன்னும் time வேணும்",
        "எனக்கு தோணுது நமக்கு இன்னும் time வேணும்."),

    PolishScenario("no-translate-ta",
        "நான் இப்ப office போறேன் அப்புறம் call பண்றேன்",
        "நான் இப்ப office போறேன் அப்புறம் call பண்றேன்."),

    PolishScenario("preserve-ta",
        "டா என்ன பண்ணிட்டு இருக்கே",
        "டா என்ன பண்ணிட்டு இருக்கே?", "டா என்ன பண்ணிட்டு இருக்கே."),
    PolishScenario("preserve-ta",
        "சரி அப்புறம் பேசலாம்",
        "சரி அப்புறம் பேசலாம்."),
]

// swiftlint:enable line_length
