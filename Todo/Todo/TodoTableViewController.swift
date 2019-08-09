import MongoSwift
import UIKit
import FBSDKLoginKit
import GoogleSignIn
import StitchRemoteMongoDBService

class TodoTableViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, ChangeStreamDelegate {
    typealias DocumentT = TodoItem // Declare Document type for ChangeStreamDelegate

    let tableView = UITableView() // Create our tableview

    private var userId: String? {
        return stitch.auth.currentUser?.id
    }

    fileprivate var todoItems = [TodoItem]() // our table view data source
    var changeStreamSession: ChangeStreamSession<TodoItem>? // our watch change stream session

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nil, bundle: nil)
        // check to make sure a user is logged in
        // if they are, load the user's todo items and refresh the tableview
        if stitch.auth.isLoggedIn {
            addWatchToCollection()
            itemsCollection.find(["owner_id": self.userId!]).toArray { result in
                switch result {
                case .success(let todos):
                    self.todoItems = todos
                    DispatchQueue.main.async {
                        self.tableView.reloadData()
                    }
                case .failure(let e):
                    fatalError(e.localizedDescription)
                }
            }
        } else {
            // no user is logged in, send them back to the welcome view
            self.navigationController?.setViewControllers([WelcomeViewController()], animated: false)
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Your To-Do List"
        self.tableView.dataSource = self
        self.tableView.delegate = self
        view.addSubview(self.tableView)
        self.tableView.frame = self.view.frame

        let addButton = UIBarButtonItem(barButtonSystemItem: .add,
            target: self,
            action: #selector(self.addTodoItem(_:)))
        let logoutButton = UIBarButtonItem(title: "Logout",
            style: .plain,
            target: self,
            action: #selector(self.logout(_:)))

        navigationItem.leftBarButtonItem = addButton
        navigationItem.rightBarButtonItem = logoutButton
    }

    @objc func logout(_ sender: Any) {

        if stitch.auth.currentUser?.loggedInProviderType == .some(.facebook) {
            LoginManager().logOut()
        }
        if stitch.auth.currentUser?.loggedInProviderType == .some(.google) {
            GIDSignIn.sharedInstance()?.signOut()
        }
        stitch.auth.logout { result in
            switch result {
            case .failure(let e):
                print("Had an error logging out: \(e)")
            case .success:
                DispatchQueue.main.async {
                    self.navigationController?.setViewControllers([WelcomeViewController()], animated: false)
                }
            }
        }
    }

    @objc func addTodoItem(_ sender: Any) {
        let alertController = UIAlertController(title: "Add Item", message: nil, preferredStyle: .alert)
        alertController.addTextField { textField in
            textField.placeholder = "ToDo item"
        }
        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alertController.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
            if let task = alertController.textFields?.first?.text {
                let todoItem = TodoItem(id: ObjectId(),
                    ownerId: self.userId!,
                    task: task,
                    checked: false)
                // optimistically add the item and reload the data
                self.todoItems.append(todoItem)
                self.tableView.reloadData()
                itemsCollection.insertOne(todoItem) { result in
                    switch result {
                    case .failure(let e):
                        print("error inserting item, \(e.localizedDescription)")
                        // an error occured, so remove the item we just inserted and reload the data again to refresh the ui
                        DispatchQueue.main.async {
                            self.todoItems.removeLast()
                            self.tableView.reloadData()
                        }
                    case .success:
                        // no action necessary
                        print("successfully inserted a document")
                    }
                }
            }
        }))
        self.present(alertController, animated: true)
    }

    func tableView(_ tableView: UITableView,
        shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        return false
    }

    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        var item = self.todoItems[indexPath.row]
        let title = item.checked ? NSLocalizedString("Undone", comment: "Undone") : NSLocalizedString("Done", comment: "Done")
        let action = UIContextualAction(style: .normal, title: title, handler: { _, _, completionHander in
            item.checked = !item.checked
            self.todoItems[indexPath.row] = item
            DispatchQueue.main.async {
                self.tableView.reloadData()
                completionHander(true)
            }
        })

        action.backgroundColor = item.checked ? .red : .green
        let configuration = UISwipeActionsConfiguration(actions: [action])
        return configuration
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard case .delete = editingStyle else { return }
        let item = todoItems[indexPath.row]
        itemsCollection.deleteOne(["_id": item.id]) { result in
            switch result {
            case .failure(let e):
                print("Error, could not delete: \(e.localizedDescription)")
            case .success:
                self.todoItems.remove(at: indexPath.row)
                DispatchQueue.main.async {
                    self.tableView.reloadData()
                }
            }
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.todoItems.count
    }

    func tableView(_ tableView: UITableView,
        cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "TodoCell") ?? UITableViewCell(style: .default, reuseIdentifier: "TodoCell")
        cell.selectionStyle = .none
        let item = todoItems[indexPath.row]
        cell.textLabel?.text = item.task
        cell.accessoryType = item.checked ? UITableViewCell.AccessoryType.checkmark : UITableViewCell.AccessoryType.none
        return cell
    }

    // Starts watching the items collection for changes.
    func addWatchToCollection() {
        do {
            NSLog("Watching changes for user \(userId!)");
            changeStreamSession = try itemsCollection.watch(delegate: self);
        } catch {
            NSLog("Stitch error: \(error)");
        }
    }

    // Implementation of the ChangeStreamDelegate protocol. Called when the matchFilter matches the change event.
    func didReceive(event: ChangeEvent<DocumentT>) {
        // Update or insert events have a fullDocument field containing the new document.
        // Delete events do not have this field.
        if let item = event.fullDocument {
            NSLog("Item refreshed: \(item)");
            DispatchQueue.main.async { [weak self] in
                // Try to find the item in the array by id.
                if let index = self?.todoItems.firstIndex(where: { $0.id == item.id }) {
                    // Item was already in the list. Here we update it.
                    self?.todoItems[index] = item
                } else {
                    // Item was not already in list, so it's a new item. Add it.
                    self?.todoItems.append(item)
                }
                // Refresh the view.
                self?.tableView.reloadData()
            }
        } else if let id = event.documentKey["_id"] as? ObjectId {
            // We can still retrieve the id of the deleted document in the event's
            // documentKey field.
            NSLog("Item deleted: \(id)");
            DispatchQueue.main.async { [weak self] in
                // Remove the deleted item from the list.
                self?.todoItems.removeAll { $0.id == id }

                // Refresh the view.
                self?.tableView.reloadData()
            }
        }
    }

    // Implementation of the ChangeStreamDelegate protocol
    func didReceive(streamError: Error) {
    }

    // Implementation of the ChangeStreamDelegate protocol
    func didOpen() {
    }

    // Implementation of the ChangeStreamDelegate protocol
    func didClose() {
    }
}
