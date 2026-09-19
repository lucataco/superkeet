"""Hand-authored synthetic smoke cases, not a real-user accuracy benchmark.

Slot annotations use exact source spans. Browser names occupy `browser`; `app`
is reserved for non-browser applications. Compound app+URL commands are open_url.
"""

GROUPS = {
    "open_app": [
        ("Open Calculator", {"app": "Calculator"}),
        ("Launch Notes", {"app": "Notes"}),
        ("Start Calendar", {"app": "Calendar"}),
        ("Open the Music app", {"app": "Music"}),
        ("Launch Preview please", {"app": "Preview"}),
        ("Can you open Mail?", {"app": "Mail"}),
        ("Open Safari", {"browser": "Safari"}),
        ("Launch Firefox", {"browser": "Firefox"}),
        ("Start Helium", {"browser": "Helium"}),
        ("Please open Terminal", {"app": "Terminal"}),
    ],
    "open_url": [
        ("Open https://example.com", {"url": "https://example.com"}),
        ("Go to youtube.com", {"url": "youtube.com"}),
        ("Open Helium and go to youtube.com", {"browser": "Helium", "url": "youtube.com"}),
        ("Navigate to https://swift.org in Safari", {"browser": "Safari", "url": "https://swift.org"}),
        ("Visit wikipedia.org", {"url": "wikipedia.org"}),
        ("Open github.com in Firefox", {"url": "github.com", "browser": "Firefox"}),
        ("Load https://example.com/docs", {"url": "https://example.com/docs"}),
        ("Take me to apple.com", {"url": "apple.com"}),
        ("Open Chrome to https://example.org", {"browser": "Chrome", "url": "https://example.org"}),
        ("Browse to https://python.org", {"url": "https://python.org"}),
    ],
    "web_search": [
        ("Search for red pandas", {"query": "red pandas"}),
        ("Search the web for sourdough recipes", {"query": "sourdough recipes"}),
        ("Google weather tomorrow", {"query": "weather tomorrow"}),
        ("Look up Swift concurrency", {"query": "Swift concurrency"}),
        ("Search for hiking trails in Safari", {"query": "hiking trails", "browser": "Safari"}),
        ("Find information about lunar eclipses", {"query": "lunar eclipses"}),
        ("Search the internet for electric bikes", {"query": "electric bikes"}),
        ("Do a web search for pasta recipes", {"query": "pasta recipes"}),
        ("Look up the history of chess", {"query": "history of chess"}),
        ("Search Firefox for local museums", {"browser": "Firefox", "query": "local museums"}),
    ],
    "switch_app": [
        ("Switch to Notes", {"app": "Notes"}),
        ("Bring Calculator to the front", {"app": "Calculator"}),
        ("Focus Terminal", {"app": "Terminal"}),
        ("Activate Mail", {"app": "Mail"}),
        ("Switch over to Calendar", {"app": "Calendar"}),
        ("Show the Preview window", {"app": "Preview"}),
        ("Bring Safari forward", {"browser": "Safari"}),
        ("Switch to Firefox", {"browser": "Firefox"}),
        ("Focus the Music app", {"app": "Music"}),
        ("Make Helium the active app", {"browser": "Helium"}),
    ],
    "click": [
        ("Click Save", {"target": "Save"}),
        ("Click the Cancel button", {"target": "Cancel"}),
        ("Press the Submit button", {"target": "Submit"}),
        ("Click Continue in Safari", {"target": "Continue", "browser": "Safari"}),
        ("Select the Settings button", {"target": "Settings"}),
        ("Click the Next link", {"target": "Next"}),
        ("Click Done in Notes", {"target": "Done", "app": "Notes"}),
        ("Tap the Search icon", {"target": "Search"}),
        ("Click the Close button", {"target": "Close"}),
        ("Click Learn more", {"target": "Learn more"}),
    ],
    "type_text": [
        ("Type hello world", {"text": "hello world"}),
        ("Enter test@example.com", {"text": "test@example.com"}),
        ("Type Good morning into Notes", {"text": "Good morning", "app": "Notes"}),
        ("Fill the search field with red pandas", {"target": "search", "text": "red pandas"}),
        ("Type 12345", {"text": "12345"}),
        ("Enter Hello, Alex!", {"text": "Hello, Alex!"}),
        ("Type meeting notes", {"text": "meeting notes"}),
        ("Write See you tomorrow in the message field", {"text": "See you tomorrow", "target": "message"}),
        ("Type https://example.com", {"text": "https://example.com"}),
        ("Enter blue sky in the title field", {"text": "blue sky", "target": "title"}),
    ],
    "press_key": [
        ("Press Enter", {"target": "Enter"}),
        ("Hit Escape", {"target": "Escape"}),
        ("Press Command C", {"target": "Command C"}),
        ("Press Tab", {"target": "Tab"}),
        ("Hit the space key", {"target": "space"}),
        ("Press the up arrow key", {"target": "up arrow"}),
        ("Press Command V", {"target": "Command V"}),
        ("Press Shift Tab", {"target": "Shift Tab"}),
        ("Hit Backspace", {"target": "Backspace"}),
        ("Press Return in Terminal", {"target": "Return", "app": "Terminal"}),
    ],
    "scroll": [
        ("Scroll down", {}), ("Scroll up", {}), ("Scroll to the bottom", {}),
        ("Scroll down in Safari", {"browser": "Safari"}), ("Scroll left", {}),
        ("Scroll right", {}), ("Scroll up a little", {}), ("Scroll down one page", {}),
        ("Scroll to the top in Notes", {"app": "Notes"}), ("Scroll further down", {}),
    ],
    "read_screen": [
        ("Read the screen", {}), ("What is on my screen?", {}),
        ("Read the current window", {}), ("Describe what you see", {}),
        ("Read the page in Safari", {"browser": "Safari"}),
        ("What does the dialog say?", {}), ("Read the visible text", {}),
        ("Tell me what is displayed", {}), ("Read the error message", {}),
        ("Read the screen in Firefox", {"browser": "Firefox"}),
    ],
    "other": [
        ("Organize my downloads", {}), ("Tell me a joke", {}),
        ("Delete all my old files", {}), ("What is two plus two?", {}),
        ("Send this email", {}), ("Rename this document", {}),
        ("Install the updates", {}), ("Make a presentation", {}),
        ("Plan my vacation", {}), ("Turn off the computer", {}),
    ],
}


def intent_cases():
    return [
        {"id": f"{action}-{index + 1}", "text": text, "action": action, "slots": slots}
        for action, cases in GROUPS.items() for index, (text, slots) in enumerate(cases)
    ]
