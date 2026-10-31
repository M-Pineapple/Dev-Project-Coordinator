# Claude Project Coordinator - Analytics Examples

This document shows example tool output. v2.0.0 uses the same headings and numbers. Heat levels are words (`quiet` / `warm` / `active` / `hot`) rather than emoji. Health groups keep the v1 band names.

## 📊 Analytics Commands & Real Output

### 1. Activity Heat Map

**Command**: "Show my project activity this week"

**Output**:
```
## Project Activity Heat Map (Past 7 Days)

hot **TodoApp** (15 activity points - 6 events)
hot **WeatherStation** (12 activity points - 5 events)
active **PortfolioSite** (8 activity points - 3 events)
warm **NotesSync** (3 activity points - 2 events)
quiet **OldBlogEngine** (0 activity points)
quiet **TestProject** (0 activity points)

### Daily Activity Breakdown:
- Monday, Jun 10: 4 events
- Tuesday, Jun 11: 8 events
- Wednesday, Jun 12: 3 events
- Thursday, Jun 13: 5 events
- Friday, Jun 14: 2 events
- Saturday, Jun 15: 0 events
- Sunday, Jun 16: 1 event

**Most Active Day**: Tuesday with 8 events across 4 projects
```

### 2. Project Timeline

**Command**: "How long has TodoApp been in development?"

**Output**:
```
## Status Timeline for TodoApp

**Current Status**: Testing & Polish (for 2 days, 6 hours)

### Previous Statuses:
- **UI Implementation**: 4 days, 18 hours
- **Core Features**: 7 days, 3 hours
- **Backend Setup**: 3 days, 12 hours
- **Planning & Design**: 2 days

**Total Project Age**: 19 days, 15 hours
```

### 3. Technology Trends

**Command**: "What technologies am I using most?"

**Output**:
```
## Technology Analysis

### Framework Usage:
- **SwiftUI**: 75% of projects (9/12)
  - Used in: TodoApp, WeatherStation, PortfolioSite
- **UIKit**: 25% of projects (3/12)
  - Used in: OldBlogEngine, LegacyTracker, ClassicNotes
- **Combine**: 58% of projects (7/12)
- **Core Data**: 42% of projects (5/12)
- **CloudKit**: 17% of projects (2/12)

### Emerging Technologies:
- **WidgetKit** (exploring in: WeatherStation)
- **App Clips** (testing in: TodoApp)
- **SwiftData** (experimenting in: NotesSync)

### Recent Technology Adoptions:
- SwiftUI: Last used today
- Combine: Last used yesterday
- async/await: Last used 2 days ago
- SwiftData: Last used 3 days ago
- WidgetKit: Last used 5 days ago

**Trend**: Moving from UIKit to SwiftUI (75% adoption rate)
```

### 4. Project Health Report

**Command**: "Which projects need my attention?"

**Output**:
```
## Project Health Report

### Critical (Needs Immediate Attention):
#### OldBlogEngine (Health: 28/100)
  - low Activity Level: 0/100 - 0 events in last 30 days
  - low Freshness: 10/100 - Last updated 45 days ago
  - low Documentation Quality: 25/100 - Needs more documentation
  - ok Task Completion: 75/100 - 3/4 tasks completed
  - **Recommendations**: Increase project activity, Update project status, Add project documentation

#### TestProject (Health: 35/100)
  - low Activity Level: 5/100 - 1 event in last 30 days
  - low Freshness: 30/100 - Last updated 15 days ago
  - watch Documentation Quality: 50/100 - Needs more documentation
  - watch Task Completion: 50/100 - 2/4 tasks completed
  - **Recommendations**: Increase project activity, Update project status

### Needs Attention:
#### NotesSync (Health: 65/100)
  - watch Activity Level: 40/100 - 3 events in last 30 days
  - ok Freshness: 90/100 - Last updated 2 days ago
  - ok Documentation Quality: 100/100 - Well documented
  - low Task Completion: 30/100 - 3/10 tasks completed
  - **Recommendations**: Focus on completing tasks

### Healthy Projects:
- **TodoApp** (Health: 92/100)
- **WeatherStation** (Health: 88/100)
- **PortfolioSite** (Health: 85/100)

**Overall Portfolio Health**: 68/100 (Needs Attention)
```

## 🎯 Productive Setup Prompts

### Initial Project Setup
```
"I want to set up project tracking for my iOS development work. I have several SwiftUI projects in ~/Developer and I work on them throughout the week. Please help me add my main projects and set appropriate statuses."
```

### Bulk Project Import
```
"Please scan ~/Developer and add all Xcode projects you find. Set status to 'Active' for any modified in the last 7 days, 'On Hold' for 30+ days, and 'Archived' for 90+ days."
```

### Regular Status Updates
```
"I just finished the authentication flow for TodoApp and I'm moving to push notifications next. Update the project status and add a note about what was completed."
```

### Weekly Review Workflow
```
"It's Friday afternoon. Show me a complete weekly review: activity heat map, projects needing attention, and what I accomplished this week. Then help me plan next week's priorities."
```

### Technology Audit
```
"Analyze my technology usage across all projects. Which frameworks am I using most? Are there any outdated technologies I should migrate away from?"
```

### Project Health Checkup
```
"Do a health check on all my projects. For any critical ones, help me decide whether to archive, revive, or delete them. For healthy ones, what can I do to maintain momentum?"
```

### Sprint Planning Helper
```
"I'm starting a new 2-week sprint. Based on project health and recent activity, which 3 projects should I focus on? Help me set specific goals for each."
```

## 💡 Claude Desktop User Preferences

Add these to your Claude Desktop preferences for optimal CPC usage:

### Basic Setup
```
When using Claude Project Coordinator (CPC):
- Always check project health before suggesting what to work on
- Remind me to update project status after discussing implementation details
- When I mention a project name, automatically show its current status
- Flag any project that hasn't been updated in 14+ days
```

### Advanced Workflow
```
CPC Analytics Preferences:
- Every Monday: Show weekly planning view (health report + activity heat map)
- Every Friday: Generate weekly accomplishment summary
- When adding new projects: Auto-detect tech stack and suggest similar projects
- For status updates: Always track the previous status duration
- Alert me when a project stays in "Planning" for more than 7 days
- Suggest archiving projects with 0 activity for 30+ days
```

### Developer Productivity
```
For my development workflow:
- When I say "start working on [project]", show its status, last notes, and pending tasks
- When I say "done for today", summarize what I worked on and update relevant project statuses
- Track which technologies I use most and suggest learning resources for emerging ones
- If I'm stuck on a project for 3+ days, suggest breaking it into smaller tasks
```

### Smart Suggestions
```
Proactive CPC assistance:
- If I mention being busy/overwhelmed, show only my top 3 healthiest active projects
- When starting new projects, warn if I have 5+ projects in "Active Development"
- Suggest "Quick Win" projects (high health, few remaining tasks) when I need motivation
- Friday reminder: "Which projects made progress this week? Let's update their statuses"
```

## 📈 Example Conversation Flow

```
You: "Good morning! What should I focus on today?"

Claude: Let me check your project analytics...

## Today's Focus (Based on Analytics)

🎯 **Priority Project**: TodoApp (Health: 92/100)
- Currently in "Testing & Polish" for 2 days
- 2 remaining tasks: Polish animations, Submit to App Store
- High momentum - let's maintain it!

⚠️ **Needs Attention**: NotesSync
- 7 uncompleted tasks piling up
- Last meaningful update: 3 days ago
- Suggestion: Dedicate 1-2 hours to clear blockers

💡 **Quick Win Available**: WeatherStation
- Only 1 task remaining: "Add weather alerts"
- Could complete and ship today!

Your recent pattern shows highest productivity on Tuesdays and Thursdays.
Today's Thursday - perfect for tackling that WeatherStation feature!

Shall I show more details for any of these projects?
```

## 🚀 Getting Started

1. Install CPC following the README instructions
2. Add a few projects to start tracking
3. Use the analytics commands after a few days of normal usage
4. Set up Claude Desktop preferences for automated insights
5. Enjoy data-driven project management!

Remember: The more you use CPC, the more valuable the analytics become!
