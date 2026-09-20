output "budget_name" {
  description = "Budget guarding this platform."
  value       = aws_budgets_budget.platform.name
}
