import Foundation

/// JSON fixtures byte-for-byte in the shape the ERPNext API returns them.
/// Embedded as source so demo mode needs no bundle/resource plumbing and the
/// package tests can decode them directly.
enum DemoFixtures {

    /// `frappe.desk.query_report.run` for "Profit and Loss Statement",
    /// FY 2025, quarterly. Group rows carry rolled-up totals; total rows use
    /// Frappe's quoted-label convention; `{}` rows are section spacers.
    static let profitAndLoss = #"""
        {
          "message": {
            "columns": [
              {"fieldname": "account", "label": "Account", "fieldtype": "Data", "width": 300},
              {"fieldname": "q1_2025", "label": "Jan – Mar 2025", "fieldtype": "Currency", "options": "currency", "width": 150},
              {"fieldname": "q2_2025", "label": "Apr – Jun 2025", "fieldtype": "Currency", "options": "currency", "width": 150},
              {"fieldname": "q3_2025", "label": "Jul – Sep 2025", "fieldtype": "Currency", "options": "currency", "width": 150},
              {"fieldname": "q4_2025", "label": "Oct – Dec 2025", "fieldtype": "Currency", "options": "currency", "width": 150},
              {"fieldname": "total", "label": "Total", "fieldtype": "Currency", "options": "currency", "width": 150}
            ],
            "result": [
              {"account": "Income - WPL", "account_name": "Income", "indent": 0, "has_value": true, "currency": "USD",
               "q1_2025": 208150.0, "q2_2025": 233010.0, "q3_2025": 231520.0, "q4_2025": 268790.0, "total": 941470.0},
              {"account": "Direct Income - WPL", "account_name": "Direct Income", "indent": 1, "has_value": true, "currency": "USD",
               "q1_2025": 206950.0, "q2_2025": 232060.0, "q3_2025": 229920.0, "q4_2025": 266690.0, "total": 935620.0},
              {"account": "Sales - WPL", "account_name": "Sales", "indent": 2, "has_value": true, "currency": "USD",
               "q1_2025": 182450.0, "q2_2025": 205310.0, "q3_2025": 198720.0, "q4_2025": 236890.0, "total": 823370.0},
              {"account": "Service - WPL", "account_name": "Service", "indent": 2, "has_value": true, "currency": "USD",
               "q1_2025": 24500.0, "q2_2025": 26750.0, "q3_2025": 31200.0, "q4_2025": 29800.0, "total": 112250.0},
              {"account": "Indirect Income - WPL", "account_name": "Indirect Income", "indent": 1, "has_value": true, "currency": "USD",
               "q1_2025": 1200.0, "q2_2025": 950.0, "q3_2025": 1600.0, "q4_2025": 2100.0, "total": 5850.0},
              {"account": "'Total Income (Credit)'", "account_name": "'Total Income (Credit)'", "indent": 0, "has_value": true, "currency": "USD",
               "q1_2025": 208150.0, "q2_2025": 233010.0, "q3_2025": 231520.0, "q4_2025": 268790.0, "total": 941470.0},
              {},
              {"account": "Expenses - WPL", "account_name": "Expenses", "indent": 0, "has_value": true, "currency": "USD",
               "q1_2025": 161550.0, "q2_2025": 175330.0, "q3_2025": 171340.0, "q4_2025": 200210.0, "total": 708430.0},
              {"account": "Direct Expenses - WPL", "account_name": "Direct Expenses", "indent": 1, "has_value": true, "currency": "USD",
               "q1_2025": 98400.0, "q2_2025": 111250.0, "q3_2025": 106800.0, "q4_2025": 128300.0, "total": 444750.0},
              {"account": "Cost of Goods Sold - WPL", "account_name": "Cost of Goods Sold", "indent": 2, "has_value": true, "currency": "USD",
               "q1_2025": 98400.0, "q2_2025": 111250.0, "q3_2025": 106800.0, "q4_2025": 128300.0, "total": 444750.0},
              {"account": "Indirect Expenses - WPL", "account_name": "Indirect Expenses", "indent": 1, "has_value": true, "currency": "USD",
               "q1_2025": 63150.0, "q2_2025": 64080.0, "q3_2025": 64540.0, "q4_2025": 71910.0, "total": 263680.0},
              {"account": "Salaries and Wages - WPL", "account_name": "Salaries and Wages", "indent": 2, "has_value": true, "currency": "USD",
               "q1_2025": 45200.0, "q2_2025": 45200.0, "q3_2025": 47800.0, "q4_2025": 47800.0, "total": 186000.0},
              {"account": "Rent - WPL", "account_name": "Rent", "indent": 2, "has_value": true, "currency": "USD",
               "q1_2025": 9000.0, "q2_2025": 9000.0, "q3_2025": 9000.0, "q4_2025": 9000.0, "total": 36000.0},
              {"account": "Utilities - WPL", "account_name": "Utilities", "indent": 2, "has_value": true, "currency": "USD",
               "q1_2025": 2150.0, "q2_2025": 1980.0, "q3_2025": 2340.0, "q4_2025": 2510.0, "total": 8980.0},
              {"account": "Marketing - WPL", "account_name": "Marketing", "indent": 2, "has_value": true, "currency": "USD",
               "q1_2025": 6800.0, "q2_2025": 7900.0, "q3_2025": 5400.0, "q4_2025": 12600.0, "total": 32700.0},
              {"account": "'Total Expense (Debit)'", "account_name": "'Total Expense (Debit)'", "indent": 0, "has_value": true, "currency": "USD",
               "q1_2025": 161550.0, "q2_2025": 175330.0, "q3_2025": 171340.0, "q4_2025": 200210.0, "total": 708430.0},
              {},
              {"account": "'Profit for the year'", "account_name": "'Profit for the year'", "indent": 0, "has_value": true, "currency": "USD",
               "q1_2025": 46600.0, "q2_2025": 57680.0, "q3_2025": 60180.0, "q4_2025": 68580.0, "total": 233040.0}
            ],
            "report_summary": [
              {"value": 941470.0, "label": "Total Income", "datatype": "Currency", "currency": "USD"},
              {"value": 708430.0, "label": "Total Expense", "datatype": "Currency", "currency": "USD"},
              {"value": 233040.0, "label": "Net Profit", "datatype": "Currency", "currency": "USD", "indicator": "Green"}
            ],
            "chart": {
              "type": "bar",
              "data": {
                "labels": ["Q1 2025", "Q2 2025", "Q3 2025", "Q4 2025"],
                "datasets": [
                  {"name": "Income", "values": [208150.0, 233010.0, 231520.0, 268790.0]},
                  {"name": "Expense", "values": [161550.0, 175330.0, 171340.0, 200210.0]}
                ]
              }
            }
          }
        }
        """#

    /// "Balance Sheet", FY 2025, yearly, accumulated.
    static let balanceSheet = #"""
        {
          "message": {
            "columns": [
              {"fieldname": "account", "label": "Account", "fieldtype": "Data", "width": 300},
              {"fieldname": "2025", "label": "2025", "fieldtype": "Currency", "options": "currency", "width": 170}
            ],
            "result": [
              {"account": "Application of Funds (Assets) - WPL", "account_name": "Application of Funds (Assets)", "indent": 0, "has_value": true, "currency": "USD", "2025": 512300.0},
              {"account": "Current Assets - WPL", "account_name": "Current Assets", "indent": 1, "has_value": true, "currency": "USD", "2025": 342300.0},
              {"account": "Bank Accounts - WPL", "account_name": "Bank Accounts", "indent": 2, "has_value": true, "currency": "USD", "2025": 120400.0},
              {"account": "Cash In Hand - WPL", "account_name": "Cash In Hand", "indent": 2, "has_value": true, "currency": "USD", "2025": 5600.0},
              {"account": "Accounts Receivable - WPL", "account_name": "Accounts Receivable", "indent": 2, "has_value": true, "currency": "USD", "2025": 96300.0},
              {"account": "Stock In Hand - WPL", "account_name": "Stock In Hand", "indent": 2, "has_value": true, "currency": "USD", "2025": 120000.0},
              {"account": "Fixed Assets - WPL", "account_name": "Fixed Assets", "indent": 1, "has_value": true, "currency": "USD", "2025": 170000.0},
              {"account": "'Total Asset (Debit)'", "account_name": "'Total Asset (Debit)'", "indent": 0, "has_value": true, "currency": "USD", "2025": 512300.0},
              {},
              {"account": "Source of Funds (Liabilities) - WPL", "account_name": "Source of Funds (Liabilities)", "indent": 0, "has_value": true, "currency": "USD", "2025": 279260.0},
              {"account": "Current Liabilities - WPL", "account_name": "Current Liabilities", "indent": 1, "has_value": true, "currency": "USD", "2025": 142260.0},
              {"account": "Accounts Payable - WPL", "account_name": "Accounts Payable", "indent": 2, "has_value": true, "currency": "USD", "2025": 98260.0},
              {"account": "Duties and Taxes - WPL", "account_name": "Duties and Taxes", "indent": 2, "has_value": true, "currency": "USD", "2025": 44000.0},
              {"account": "Capital Account - WPL", "account_name": "Capital Account", "indent": 1, "has_value": true, "currency": "USD", "2025": 137000.0},
              {"account": "'Total Liability (Credit)'", "account_name": "'Total Liability (Credit)'", "indent": 0, "has_value": true, "currency": "USD", "2025": 279260.0},
              {},
              {"account": "'Provisional Profit / Loss (Credit)'", "account_name": "'Provisional Profit / Loss (Credit)'", "indent": 0, "has_value": true, "currency": "USD", "2025": 233040.0}
            ],
            "report_summary": [
              {"value": 512300.0, "label": "Total Asset", "datatype": "Currency", "currency": "USD"},
              {"value": 279260.0, "label": "Total Liability", "datatype": "Currency", "currency": "USD"},
              {"value": 233040.0, "label": "Provisional Profit / Loss", "datatype": "Currency", "currency": "USD", "indicator": "Green"}
            ]
          }
        }
        """#

    /// `frappe.desk.form.load.getdoctype` for Account (trimmed to the fields
    /// the demo shows; structure — section/column breaks — is faithful).
    static let accountMeta = #"""
        {
          "docs": [
            {
              "doctype": "DocType",
              "name": "Account",
              "istable": 0,
              "issingle": 0,
              "is_tree": 1,
              "title_field": "account_name",
              "fields": [
                {"fieldname": "account_name", "label": "Account Name", "fieldtype": "Data", "reqd": 1, "in_list_view": 1, "bold": 1},
                {"fieldname": "account_number", "label": "Account Number", "fieldtype": "Data", "in_list_view": 1},
                {"fieldname": "is_group", "label": "Is Group", "fieldtype": "Check"},
                {"fieldname": "company", "label": "Company", "fieldtype": "Link", "options": "Company", "reqd": 1},
                {"fieldname": "cb0", "fieldtype": "Column Break"},
                {"fieldname": "root_type", "label": "Root Type", "fieldtype": "Select", "options": "\nAsset\nLiability\nIncome\nExpense\nEquity", "in_list_view": 1, "in_standard_filter": 1},
                {"fieldname": "report_type", "label": "Report Type", "fieldtype": "Select", "options": "\nBalance Sheet\nProfit and Loss"},
                {"fieldname": "account_currency", "label": "Currency", "fieldtype": "Link", "options": "Currency"},
                {"fieldname": "sb1", "label": "Account Settings", "fieldtype": "Section Break"},
                {"fieldname": "parent_account", "label": "Parent Account", "fieldtype": "Link", "options": "Account", "reqd": 1},
                {"fieldname": "account_type", "label": "Account Type", "fieldtype": "Select", "options": "\nBank\nCash\nReceivable\nPayable\nStock\nTax\nExpense Account\nIncome Account"},
                {"fieldname": "cb1", "fieldtype": "Column Break"},
                {"fieldname": "tax_rate", "label": "Tax Rate", "fieldtype": "Percent"},
                {"fieldname": "freeze_account", "label": "Frozen", "fieldtype": "Select", "options": "No\nYes"},
                {"fieldname": "balance_must_be", "label": "Balance must be", "fieldtype": "Select", "options": "\nDebit\nCredit"},
                {"fieldname": "lft", "label": "Left", "fieldtype": "Int", "hidden": 1},
                {"fieldname": "rgt", "label": "Right", "fieldtype": "Int", "hidden": 1}
              ]
            }
          ]
        }
        """#

    static let accountList = #"""
        {
          "data": [
            {"name": "Income - WPL", "account_name": "Income", "root_type": "Income", "is_group": 1, "parent_account": "", "lft": 1},
            {"name": "Direct Income - WPL", "account_name": "Direct Income", "root_type": "Income", "is_group": 1, "parent_account": "Income - WPL", "lft": 2},
            {"name": "Sales - WPL", "account_name": "Sales", "account_number": "4110", "root_type": "Income", "is_group": 0, "parent_account": "Direct Income - WPL", "lft": 3},
            {"name": "Service - WPL", "account_name": "Service", "account_number": "4120", "root_type": "Income", "is_group": 0, "parent_account": "Direct Income - WPL", "lft": 5},
            {"name": "Expenses - WPL", "account_name": "Expenses", "root_type": "Expense", "is_group": 1, "parent_account": "", "lft": 10},
            {"name": "Direct Expenses - WPL", "account_name": "Direct Expenses", "root_type": "Expense", "is_group": 1, "parent_account": "Expenses - WPL", "lft": 11},
            {"name": "Cost of Goods Sold - WPL", "account_name": "Cost of Goods Sold", "account_number": "5111", "root_type": "Expense", "is_group": 0, "parent_account": "Direct Expenses - WPL", "lft": 12},
            {"name": "Indirect Expenses - WPL", "account_name": "Indirect Expenses", "root_type": "Expense", "is_group": 1, "parent_account": "Expenses - WPL", "lft": 14},
            {"name": "Salaries and Wages - WPL", "account_name": "Salaries and Wages", "account_number": "5211", "root_type": "Expense", "is_group": 0, "parent_account": "Indirect Expenses - WPL", "lft": 15},
            {"name": "Rent - WPL", "account_name": "Rent", "account_number": "5226", "root_type": "Expense", "is_group": 0, "parent_account": "Indirect Expenses - WPL", "lft": 17},
            {"name": "Utilities - WPL", "account_name": "Utilities", "account_number": "5230", "root_type": "Expense", "is_group": 0, "parent_account": "Indirect Expenses - WPL", "lft": 19},
            {"name": "Marketing - WPL", "account_name": "Marketing", "account_number": "5232", "root_type": "Expense", "is_group": 0, "parent_account": "Indirect Expenses - WPL", "lft": 21},
            {"name": "Application of Funds (Assets) - WPL", "account_name": "Application of Funds (Assets)", "root_type": "Asset", "is_group": 1, "parent_account": "", "lft": 30},
            {"name": "Bank Accounts - WPL", "account_name": "Bank Accounts", "account_number": "1110", "root_type": "Asset", "is_group": 0, "parent_account": "Application of Funds (Assets) - WPL", "lft": 31},
            {"name": "Accounts Receivable - WPL", "account_name": "Accounts Receivable", "account_number": "1310", "root_type": "Asset", "is_group": 0, "parent_account": "Application of Funds (Assets) - WPL", "lft": 33},
            {"name": "Accounts Payable - WPL", "account_name": "Accounts Payable", "account_number": "2110", "root_type": "Liability", "is_group": 0, "parent_account": "", "lft": 40}
          ]
        }
        """#

    static let accountDocs = #"""
        {
          "data": [
            {"name": "Sales - WPL", "account_name": "Sales", "account_number": "4110", "is_group": 0,
             "company": "Wind Power LLC", "root_type": "Income", "report_type": "Profit and Loss",
             "account_currency": "USD", "parent_account": "Direct Income - WPL",
             "account_type": "Income Account", "tax_rate": 0.0, "freeze_account": "No"},
            {"name": "Accounts Receivable - WPL", "account_name": "Accounts Receivable", "account_number": "1310", "is_group": 0,
             "company": "Wind Power LLC", "root_type": "Asset", "report_type": "Balance Sheet",
             "account_currency": "USD", "parent_account": "Current Assets - WPL",
             "account_type": "Receivable", "freeze_account": "No", "balance_must_be": "Debit"}
          ]
        }
        """#

    /// Sales Invoice, heavily trimmed but structurally faithful: tab breaks,
    /// sections, columns, a child table, currency fields, a status Select.
    static let salesInvoiceMeta = #"""
        {
          "docs": [
            {
              "doctype": "DocType",
              "name": "Sales Invoice",
              "istable": 0,
              "issingle": 0,
              "is_submittable": 1,
              "title_field": "customer_name",
              "links": [
                {"link_doctype": "Payment Entry", "link_fieldname": "reference_name", "group": "Payments"},
                {"link_doctype": "Delivery Note", "link_fieldname": "against_sales_invoice", "group": "Fulfilment"}
              ],
              "fields": [
                {"fieldname": "details_tab", "label": "Details", "fieldtype": "Tab Break"},
                {"fieldname": "customer", "label": "Customer", "fieldtype": "Link", "options": "Customer", "reqd": 1, "in_standard_filter": 1},
                {"fieldname": "customer_name", "label": "Customer Name", "fieldtype": "Data", "in_list_view": 1, "bold": 1},
                {"fieldname": "cb_dates", "fieldtype": "Column Break"},
                {"fieldname": "posting_date", "label": "Date", "fieldtype": "Date", "in_list_view": 1},
                {"fieldname": "due_date", "label": "Payment Due Date", "fieldtype": "Date"},
                {"fieldname": "po_no", "label": "Customer's Purchase Order", "fieldtype": "Data"},
                {"fieldname": "cb_company", "fieldtype": "Column Break"},
                {"fieldname": "company", "label": "Company", "fieldtype": "Link", "options": "Company"},
                {"fieldname": "currency", "label": "Currency", "fieldtype": "Link", "options": "Currency"},
                {"fieldname": "items_section", "label": "Items", "fieldtype": "Section Break"},
                {"fieldname": "scan_barcode", "label": "Scan Barcode", "fieldtype": "Data", "options": "Barcode"},
                {"fieldname": "items", "label": "Items", "fieldtype": "Table", "options": "Sales Invoice Item", "reqd": 1},
                {"fieldname": "tax_breakup_section", "label": "Tax Breakup", "fieldtype": "Section Break", "collapsible": 1},
                {"fieldname": "other_charges_calculation", "label": "Taxes and Charges Calculation", "fieldtype": "Long Text", "read_only": 1},
                {"fieldname": "totals_section", "label": "Totals", "fieldtype": "Section Break"},
                {"fieldname": "total", "label": "Total", "fieldtype": "Currency", "options": "currency"},
                {"fieldname": "is_return", "label": "Is Return", "fieldtype": "Check"},
                {"fieldname": "return_against", "label": "Return Against Sales Invoice", "fieldtype": "Link", "options": "Sales Invoice", "depends_on": "eval:doc.is_return"},
                {"fieldname": "cb_totals", "fieldtype": "Column Break"},
                {"fieldname": "grand_total", "label": "Grand Total", "fieldtype": "Currency", "options": "currency", "bold": 1, "in_list_view": 1},
                {"fieldname": "base_grand_total", "label": "Grand Total (Company Currency)", "fieldtype": "Currency", "options": "currency"},
                {"fieldname": "totals_continued", "fieldtype": "Section Break"},
                {"fieldname": "outstanding_amount", "label": "Outstanding Amount", "fieldtype": "Currency", "options": "currency"},
                {"fieldname": "more_info_tab", "label": "More Info", "fieldtype": "Tab Break"},
                {"fieldname": "status", "label": "Status", "fieldtype": "Select", "in_list_view": 1, "in_standard_filter": 1,
                 "options": "\nDraft\nReturn\nCredit Note Issued\nSubmitted\nPaid\nUnpaid\nOverdue\nCancelled"},
                {"fieldname": "cb_info", "fieldtype": "Column Break"},
                {"fieldname": "remarks", "label": "Remarks", "fieldtype": "Small Text"}
              ]
            },
            {
              "doctype": "DocType",
              "name": "Sales Invoice Item",
              "istable": 1,
              "fields": [
                {"fieldname": "item_code", "label": "Item", "fieldtype": "Link", "options": "Item", "in_list_view": 1},
                {"fieldname": "item_name", "label": "Item Name", "fieldtype": "Data", "in_list_view": 1},
                {"fieldname": "qty", "label": "Quantity", "fieldtype": "Float", "in_list_view": 1},
                {"fieldname": "rate", "label": "Rate", "fieldtype": "Currency", "options": "currency", "in_list_view": 1},
                {"fieldname": "amount", "label": "Amount", "fieldtype": "Currency", "options": "currency", "in_list_view": 1}
              ]
            }
          ],
          "user_settings": "{\"GridView\": {\"Sales Invoice Item\": [{\"fieldname\": \"item_code\", \"columns\": 3}, {\"fieldname\": \"qty\", \"columns\": 2}, {\"fieldname\": \"amount\", \"columns\": 2}]}, \"List\": {\"sort_by\": \"posting_date\", \"sort_order\": \"desc\"}}"
        }
        """#

    /// A public Workspace with shortcuts, link cards, number cards, charts.
    static let workspaceDocs = #"""
        {
          "data": [
            {
              "name": "Accounting",
              "title": "Accounting",
              "public": 1,
              "shortcuts": [
                {"label": "Sales Invoices", "type": "DocType", "link_to": "Sales Invoice"},
                {"label": "Profit and Loss", "type": "Report", "link_to": "Profit and Loss Statement"}
              ],
              "links": [
                {"type": "Card Break", "label": "Receivables"},
                {"type": "Link", "label": "Sales Invoice", "link_type": "DocType", "link_to": "Sales Invoice"},
                {"type": "Link", "label": "Chart of Accounts", "link_type": "DocType", "link_to": "Account"},
                {"type": "Card Break", "label": "Reports"},
                {"type": "Link", "label": "Trial Balance", "link_type": "Report", "link_to": "Trial Balance", "is_query_report": 1}
              ],
              "number_cards": [
                {"number_card_name": "Total Outstanding", "label": "Total Outstanding"},
                {"number_card_name": "Annual Income", "label": "Annual Income"}
              ],
              "charts": [
                {"chart_name": "Income Trend", "label": "Income Trend"}
              ]
            }
          ]
        }
        """#

    static let commentDocs = #"""
        {
          "data": [
            {"name": "cmt1", "reference_doctype": "Sales Invoice", "reference_name": "ACC-SINV-2025-00042",
             "comment_type": "Comment", "comment_email": "molly@windpower.example",
             "creation": "2025-07-20 10:12:00",
             "content": "<p>Confirmed receipt with Northwind — payment cleared same week.</p>"}
          ]
        }
        """#

    static let versionDocs = #"""
        {
          "data": [
            {"name": "v2", "ref_doctype": "Sales Invoice", "docname": "ACC-SINV-2025-00042",
             "owner": "tom@twarge.com", "creation": "2025-08-18 09:30:00",
             "data": "{\"changed\": [[\"status\", \"Unpaid\", \"Paid\"], [\"outstanding_amount\", 13807.5, 0]]}"},
            {"name": "v1", "ref_doctype": "Sales Invoice", "docname": "ACC-SINV-2025-00042",
             "owner": "molly@windpower.example", "creation": "2025-07-18 15:02:00",
             "data": "{\"changed\": [[\"remarks\", null, \"Q3 restock order. Delivered in two shipments.\"]]}"}
          ]
        }
        """#

    static let shareDocs = #"""
        {
          "data": [
            {"name": "shr1", "share_doctype": "Sales Invoice", "share_name": "ACC-SINV-2025-00042",
             "user": "molly@windpower.example", "read": 1, "write": 0}
          ]
        }
        """#

    static let fileDocs = #"""
        {
          "data": [
            {"name": "file1", "attached_to_doctype": "Sales Invoice", "attached_to_name": "ACC-SINV-2025-00042",
             "file_name": "PO-4451.txt", "file_url": "/files/PO-4451.txt", "is_private": 1, "file_size": 512}
          ]
        }
        """#

    static let salesInvoiceList = #"""
        {
          "data": [
            {"name": "ACC-SINV-2025-00042", "customer": "Northwind Research", "customer_name": "Northwind Research", "posting_date": "2025-07-18", "grand_total": 13807.5, "status": "Paid"},
            {"name": "ACC-SINV-2025-00041", "customer": "Grant Plastics Ltd.", "customer_name": "Grant Plastics Ltd.", "posting_date": "2025-07-11", "grand_total": 5720.0, "status": "Paid"},
            {"name": "ACC-SINV-2025-00040", "customer": "Zany Brainy", "customer_name": "Zany Brainy", "posting_date": "2025-07-02", "grand_total": 21480.0, "status": "Unpaid"},
            {"name": "ACC-SINV-2025-00039", "customer": "Northwind Research", "customer_name": "Northwind Research", "posting_date": "2025-06-24", "grand_total": 8900.0, "status": "Overdue"}
          ]
        }
        """#

    static let salesInvoiceDocs = #"""
        {
          "data": [
            {
              "name": "ACC-SINV-2025-00042",
              "docstatus": 1,
              "_assign": "[\"tom@twarge.com\"]",
              "_liked_by": "[\"molly@windpower.example\"]",
              "_user_tags": ",wholesale,priority",
              "customer": "Northwind Research",
              "customer_name": "Northwind Research",
              "posting_date": "2025-07-18",
              "due_date": "2025-08-17",
              "company": "Wind Power LLC",
              "currency": "USD",
              "conversion_rate": 1.0,
              "is_return": 0,
              "other_charges_calculation": "<div class=\"tax-break-up\" style=\"overflow-x: auto;\"><table class=\"table table-bordered table-hover\"><thead><tr><th class=\"text-left\">Item</th><th class=\"text-right\">Taxable Amount</th><th class=\"text-right\">Shipping &amp; Handling</th></tr></thead><tbody><tr><td>WT-1000</td><td class=\"text-right\">$ 7,400.00</td><td class=\"text-right\">(5.0%)<br>$ 370.00</td></tr><tr><td>WT-2400</td><td class=\"text-right\">$ 4,800.00</td><td class=\"text-right\">(5.0%)<br>$ 240.00</td></tr><tr><td>MNT-KIT</td><td class=\"text-right\">$ 950.00</td><td class=\"text-right\">(5.0%)<br>$ 47.50</td></tr></tbody></table></div>",
              "items": [
                {"name": "row1", "item_code": "WT-1000", "item_name": "Wind Turbine 1kW", "qty": 4.0, "rate": 1850.0, "amount": 7400.0},
                {"name": "row2", "item_code": "WT-2400", "item_name": "Wind Turbine 2.4kW", "qty": 2.0, "rate": 2400.0, "amount": 4800.0},
                {"name": "row3", "item_code": "MNT-KIT", "item_name": "Mounting Kit", "qty": 10.0, "rate": 95.0, "amount": 950.0}
              ],
              "total": 13150.0,
              "grand_total": 13807.5,
              "base_grand_total": 13807.5,
              "outstanding_amount": 0.0,
              "status": "Paid",
              "remarks": "Q3 restock order. Delivered in two shipments."
            }
          ]
        }
        """#
}
